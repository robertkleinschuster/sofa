// Sofa's hint/state datagrams and the ctl stream socket (STATUS, STATE, HINT, IDENT/IDENTSTOP, FLUSH, SIMSLEEP/SIMWAKE). This thread only reads the controller's published snapshot (pub), never cfg.
#include "fand.h"
#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <poll.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>

int pthread_setugid_np(uid_t uid, gid_t gid);   // Darwin: per-thread credentials (sys/pthread)

int lfd_hint = -1, lfd_ctl = -1;
static unsigned hints_dropped;

// Minimal strict JSON: exactly one flat object, string/number/null/true/false values, no
// duplicate keys, nothing but whitespace after the closing brace. Fills up to 8 fields.
typedef struct { char key[12]; int type; char str[24]; double num; } jfield_t;   // type: 1 str, 2 num, 3 null, 4 bool
static const char *jws(const char *p) { while (*p == ' ' || *p == '\t' || *p == '\r' || *p == '\n') p++; return p; }
static const char *jstring(const char *p, char *out, size_t cap) {
  if (*p++ != '"') return NULL;
  size_t n = 0;
  while (*p && *p != '"') { if ((unsigned char)*p < 0x20 || *p == '\\' || n + 1 >= cap) return NULL; out[n++] = *p++; }
  if (*p != '"') return NULL;
  out[n] = 0; return p + 1;
}
static int json_parse(const char *j, jfield_t *f, int max) {
  const char *p = jws(j); int n = 0;
  if (*p++ != '{') return -1;
  p = jws(p);
  if (*p == '}') return jws(p + 1)[0] ? -1 : 0;
  for (;;) {
    if (n >= max) return -1;
    jfield_t *x = &f[n];
    if (!(p = jstring(p, x->key, sizeof x->key))) return -1;
    for (int i = 0; i < n; i++) if (!strcmp(f[i].key, x->key)) return -1;
    p = jws(p); if (*p++ != ':') return -1; p = jws(p);
    if (*p == '"') { x->type = 1; if (!(p = jstring(p, x->str, sizeof x->str))) return -1; }
    else if (!strncmp(p, "null", 4)) { x->type = 3; p += 4; }
    else if (!strncmp(p, "true", 4)) { x->type = 4; x->num = 1; p += 4; }
    else if (!strncmp(p, "false", 5)) { x->type = 4; x->num = 0; p += 5; }
    else { char *e; x->num = strtod(p, &e); if (e == p || !isfinite(x->num) || (*p != '-' && (*p < '0' || *p > '9'))) return -1; x->type = 2; p = e; }
    n++;
    p = jws(p);
    if (*p == ',') { p = jws(p + 1); continue; }
    if (*p == '}') return jws(p + 1)[0] ? -1 : n;
    return -1;
  }
}
static const jfield_t *jget(const jfield_t *f, int n, const char *key) { for (int i = 0; i < n; i++) if (!strcmp(f[i].key, key)) return &f[i]; return NULL; }

int parse_hint(const char *msg, double *vol, double *ttl, int *pid) {
  jfield_t f[8]; int n = json_parse(msg, f, 8);
  if (n < 0) return -1;
  const jfield_t *v = jget(f, n, "v"), *c = jget(f, n, "ctx"), *x;
  if (!v || v->type != 2 || v->num != 1 || !c || c->type != 1) return -1;
  int p = -1;
  if (!strcmp(c->str, "ruhe")) p = P_RUHE; else if (!strcmp(c->str, "idle")) p = P_IDLE; else if (!strcmp(c->str, "playback")) p = P_PLAYBACK;
  if (p < 0) return -1;
  *vol = -1; if ((x = jget(f, n, "vol")) && x->type == 2 && x->num >= 0 && x->num <= 1) *vol = x->num;
  *ttl = 90; if ((x = jget(f, n, "ttl")) && x->type == 2) *ttl = x->num < 10 ? 10 : x->num > 300 ? 300 : x->num;
  *pid = 0; if ((x = jget(f, n, "pid")) && x->type == 2 && x->num > 0 && x->num < 1e7) *pid = (int)x->num;
  return p;
}

// sender must be a socket owned by allow_uid directly below reply_dir, no symlinks
static struct { char path[104]; double checked; int ok; } reply_cache;
static int reply_ok(const struct sockaddr_un *sa, socklen_t len) {
  if (len <= (socklen_t)offsetof(struct sockaddr_un, sun_path) || sa->sun_family != AF_UNIX) return 0;
  char dirp[128]; int uid;
  pthread_mutex_lock(&pub_mx); memcpy(dirp, pub.reply_dir, sizeof dirp); uid = pub.allow_uid; pthread_mutex_unlock(&pub_mx);
  dirp[sizeof dirp - 1] = 0;
  char path[105]; size_t n = (size_t)len - offsetof(struct sockaddr_un, sun_path);
  if (n > sizeof sa->sun_path) n = sizeof sa->sun_path;
  memcpy(path, sa->sun_path, n); path[n] = 0;
  size_t dl = strlen(dirp);
  if (!dl || strncmp(path, dirp, dl) || strchr(path + dl, '/') || !path[dl] || strstr(path, "..")) return 0;
  double now = now_s();
  if (reply_cache.ok && !strcmp(reply_cache.path, path) && now - reply_cache.checked < 30) return 1;
  // lstat may touch the disk; this thread may block, the control loop does not care
  struct stat sd, sf; char dir[128]; snprintf(dir, sizeof dir, "%.*s", (int)(dl - 1), dirp);
  // only uid allow_uid (or root) can bind a socket in a directory it owns that nobody else may
  // write: a valid sender address therefore authenticates the sender (datagrams carry no creds)
  int ok = lstat(dir, &sd) == 0 && S_ISDIR(sd.st_mode) && (int)sd.st_uid == uid && (sd.st_mode & 022) == 0 &&
           lstat(path, &sf) == 0 && S_ISSOCK(sf.st_mode) && (int)sf.st_uid == uid;
  snprintf(reply_cache.path, sizeof reply_cache.path, "%s", path); reply_cache.checked = now; reply_cache.ok = ok;
  return ok;
}

// what Sofa reads: level, mode, a few headline temperatures by role, the fans by their SMC names
static int state_json(char *b, size_t cap) {
  pub_t p; pthread_mutex_lock(&pub_mx); p = pub; pthread_mutex_unlock(&pub_mx);
  #define FIND(k) ({ int _r = -1; for (int _i = 0; _i < p.nsens; _i++) if (!strcmp(p.key[_i], k)) { _r = _i; break; } _r; })
  int ic = FIND("TC0P"), ig = FIND("TG0D"), ih = FIND(HDD_KEY), ip = FIND("Tp2H"), ia = FIND("TA0P");
  #undef FIND
  #define TV(i) ((i) >= 0 && p.temp_ok[i] ? p.temp[i] : -1.0)
  int n = snprintf(b, cap, "{\"v\":1,\"level\":%d,\"mode\":\"%s\",\"cpu_c\":%.1f,\"gpu_c\":%.1f,\"hdd_c\":%.1f,\"psu_c\":%.1f,\"amb_c\":%.1f,\"fans\":[",
                   p.level, p.mode == M_CURVE ? "curve" : p.mode == M_TRIP ? "trip" : "smc", TV(ic), TV(ig), TV(ih), TV(ip), TV(ia));
  #undef TV
  int first = 1;
  for (int f = 0; f < MAX_FANS && n > 0 && (size_t)n < cap; f++) {
    if (!p.fan_used[f]) continue;
    n += snprintf(b + n, cap - (size_t)n, "%s{\"name\":\"%s\",\"rpm\":%.0f}", first ? "" : ",", p.fan_name[f], isnan(p.ac[f]) ? -1.0 : p.ac[f]);
    first = 0;
  }
  if (n > 0 && (size_t)n < cap) n += snprintf(b + n, cap - (size_t)n, "]}\n");
  return n > 0 && (size_t)n < cap ? n : -1;
}

typedef struct { char *buf; size_t cap, o; } outbuf_t;
static void out_line(const char *line, void *ctx) {
  outbuf_t *ob = ctx;
  int k = snprintf(ob->buf + ob->o, ob->o < ob->cap ? ob->cap - ob->o : 0, "log %s\n", line);
  if (k > 0) ob->o += (size_t)k; if (ob->o >= ob->cap) ob->o = ob->cap - 1;
}

static int status_text(char *buf, size_t cap) {
  static const char *ffn[] = { "", " ff=cpu", " ff=gpu", " ff=cpu+gpu" };
  pub_t p; pthread_mutex_lock(&pub_mx); p = pub; pthread_mutex_unlock(&pub_mx);
  hint_t h; pthread_mutex_lock(&hint_mx); h = hint; pthread_mutex_unlock(&hint_mx);
  double now = now_s(); size_t o = 0;
  #define OUT(...) do { int _n = snprintf(buf + o, o < cap ? cap - o : 0, __VA_ARGS__); if (_n > 0) o += (size_t)_n; if (o >= cap) o = cap - 1; } while (0)
  OUT("mode %s (%s)%s\nlevel %d\n", mode_name[p.mode], p.reason, dry ? " DRY RUN - SMC untouched" : "", p.level);
  OUT("profile %s shift %+.1f", prof_name[p.profile], p.shift);
  if (h.ctx >= 0 && now < h.until) OUT(" (hint %.0f s left, vol %.2f, pid %d)", h.until - now, h.vol, h.pid);
  OUT("\nhints_received %u dropped %u\nload cpu %.2f gpu %.2f\n", h.count, hints_dropped, p.cpu, p.gpu);
  OUT("machine %s, %d fans\n", machine.model, machine.nfans);
  if (p.learned > 0) OUT("learned %u lines in effect (reloads %u)\n", p.learned_lines, p.cfg_gen);
  else if (p.learned < 0) OUT("learned REFUSED: %s (reloads %u)\n", p.err_learned, p.cfg_gen);
  else OUT("learned none (reloads %u)\n", p.cfg_gen);
  if (p.ident[0]) OUT("ident %s %.0f s left\n", p.ident, p.ident_left);
  for (int n = 0; n < MAX_FANS; n++) if (p.fan_used[n]) OUT("fan %d %-4s actual %5.0f target %5.0f\n", n, p.fan_name[n], p.ac[n], p.target[n]);
  for (int i = 0; i < p.nsens; i++) {
    if (p.temp_ok[i]) OUT("temp %-4s %5.1f warn %.0f trip %.0f%s\n", p.key[i], p.temp[i], p.warn[i], p.trip[i], ffn[p.ff[i]]);
    else OUT("temp %-4s  n/a  warn %.0f trip %.0f\n", p.key[i], p.warn[i], p.trip[i]);
  }
  if (sleeping) OUT("sleeping yes (FS!=0, controller paused)\n");
  OUT("memlock %lu KB\nuptime %.0f\n", control_locked_kb(), now - control_started());
  outbuf_t ob = { buf, cap, o };
  log_recent(out_line, &ob, 15);
  o = ob.o;
  OUT(".\n");
  #undef OUT
  return (int)o;
}

static void take_hint(const char *msg, const struct sockaddr_un *from, socklen_t flen, int *have_peer, struct sockaddr_un *peer, socklen_t *plen) {
  double vol, ttl; int pid;
  if (from && !reply_ok(from, flen)) { hints_dropped++; return; }    // unauthenticated sender
  int p = parse_hint(msg, &vol, &ttl, &pid);
  if (p < 0) { hints_dropped++; return; }
  double now = now_s();
  pthread_mutex_lock(&hint_mx);
  int changed = hint.ctx != p || now >= hint.until;
  if (changed) hint.changed_at = now;
  hint.ctx = p; hint.vol = vol; hint.until = now + ttl; hint.pid = pid; hint.count++;
  pthread_mutex_unlock(&hint_mx);
  static double last_log = -100;
  if (changed) poke(wake_pipe[1]);   // new context: next control step now
  if (changed && now - last_log >= 10) { last_log = now; logf_("context %s (vol %.2f, ttl %.0f, pid %d)", prof_name[p], vol, ttl, pid); }
  if (from) {
    char b[1024]; int n = state_json(b, sizeof b);
    if (n > 0) sendto(lfd_hint, b, (size_t)n, MSG_DONTWAIT, (const struct sockaddr *)from, flen);
    memcpy(peer, from, sizeof *peer); *plen = flen; *have_peer = 1;
  }
}

void *socket_thread(void *arg) {
  (void)arg;
  // This thread runs with uid allow_uid: lstat and sendto are then checked by the kernel with
  // the user's rights, so a symlink swapped in after the check cannot make root write anywhere.
  // (allow_uid as at the controller's start: a reload does not change a thread's credentials.)
  if (pthread_setugid_np((uid_t)cfg.allow_uid, (gid_t)20)) logf_("socket thread keeps root credentials (setugid failed)");
  struct sockaddr_un peer; socklen_t plen = 0; int have_peer = 0; unsigned seen_seq = 0;
  for (;;) {
    struct pollfd p[3] = { { lfd_hint, POLLIN, 0 }, { lfd_ctl, POLLIN, 0 }, { push_pipe[0], POLLIN, 0 } };
    int r = poll(p, 3, -1);                                  // event-driven: no timeout
    if (r > 0 && (p[2].revents & POLLIN)) { char b[16]; while (read(push_pipe[0], b, sizeof b) > 0) {} }
    if (r > 0 && (p[0].revents & POLLIN)) {
      char msg[HINT_MAX + 1]; struct sockaddr_un from; socklen_t fl = sizeof from;
      ssize_t n = recvfrom(lfd_hint, msg, HINT_MAX, MSG_DONTWAIT, (struct sockaddr *)&from, &fl);
      if (n > 0) { msg[n] = 0; take_hint(msg, &from, fl, &have_peer, &peer, &plen); }
    }
    if (r > 0 && (p[1].revents & POLLIN)) {
      int fd = accept(lfd_ctl, NULL, NULL);
      if (fd >= 0) {
        struct timeval tv = { 0, 300000 }; int on = 1;
        int fl = fcntl(fd, F_GETFL); if (fl >= 0) fcntl(fd, F_SETFL, fl & ~O_NONBLOCK);   // timeouts, not EAGAIN
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof tv);
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof on);
        char cmd[HINT_MAX + 1]; ssize_t n = 0;
        double deadline = now_s() + 0.5;                       // whole request within 500 ms
        while (n < HINT_MAX) {
          double left = deadline - now_s(); if (left <= 0) { n = 0; break; }
          struct pollfd pf = { fd, POLLIN, 0 };
          if (poll(&pf, 1, (int)(left * 1000) + 1) <= 0) { n = 0; break; }
          ssize_t k = read(fd, cmd + n, (size_t)(HINT_MAX - n)); if (k <= 0) break;
          n += k; if (memchr(cmd, '\n', (size_t)n)) break;
        }
        if (n > 0) {
          cmd[n] = 0; char *nl = strchr(cmd, '\n'); if (nl) *nl = 0;
          static char out[8192]; int len = 0;
          uid_t uid = (uid_t)-1; gid_t gid; if (getpeereid(fd, &uid, &gid)) uid = (uid_t)-1;
          int allow; pthread_mutex_lock(&pub_mx); allow = pub.allow_uid; pthread_mutex_unlock(&pub_mx);
          if (!strcmp(cmd, "STATUS")) len = status_text(out, sizeof out);
          else if (!strcmp(cmd, "STATE")) len = state_json(out, sizeof out);
          else if (!strncmp(cmd, "HINT ", 5) && (uid == 0 || (int)uid == allow)) { take_hint(cmd + 5, NULL, 0, &have_peer, &peer, &plen); len = snprintf(out, sizeof out, "OK\n"); }
          else if (!strncmp(cmd, "IDENT ", 6) && uid == 0) {   // IDENT SECS TAG RPM0 RPM1 ... (-1: curves)
            int rpm[MAX_FANS]; int nf = 0; double secs = 0; char tag[24] = "", e[96] = "";
            char *save = NULL, *t = strtok_r(cmd + 6, " ", &save);
            if (t) secs = atof(t);
            t = strtok_r(NULL, " ", &save); if (t) snprintf(tag, sizeof tag, "%s", t);
            while ((t = strtok_r(NULL, " ", &save)) && nf < MAX_FANS) rpm[nf++] = atoi(t);
            for (char *q = tag; *q; q++) if (*q == ',' || *q < 0x21 || *q > 0x7e) *q = '_';   // it goes into CSV rows
            if (!tag[0] || !nf) len = snprintf(out, sizeof out, "ERR usage: IDENT SECS TAG RPM...\n");
            else if (control_ident(rpm, nf, secs, tag, e, sizeof e)) len = snprintf(out, sizeof out, "ERR %s\n", e);
            else len = snprintf(out, sizeof out, "OK\n");
          }
          else if (!strcmp(cmd, "IDENTSTOP") && uid == 0) { control_ident_stop(); len = snprintf(out, sizeof out, "OK\n"); }
          else if (!strcmp(cmd, "FLUSH") && uid == 0) { record_request_flush(); len = snprintf(out, sizeof out, "OK\n"); }
          else if (!strcmp(cmd, "SIMSLEEP") && uid == 0) { power_sleep(); len = snprintf(out, sizeof out, "OK slept (FS!=0x%x)\n", fs_get()); }
          else if (!strcmp(cmd, "SIMWAKE") && uid == 0) { power_wake(); len = snprintf(out, sizeof out, "OK woke\n"); }
          else len = snprintf(out, sizeof out, "ERR\n");
          if (len > 0) { ssize_t w = write(fd, out, (size_t)len); (void)w; }
        }
        close(fd);
      }
    }
    // push the state on every level change to the last valid Sofa address
    unsigned seq; pthread_mutex_lock(&pub_mx); seq = pub.level_seq; pthread_mutex_unlock(&pub_mx);
    if (seq != seen_seq) {
      seen_seq = seq;
      if (have_peer) { char b[1024]; int n = state_json(b, sizeof b); if (n > 0) sendto(lfd_hint, b, (size_t)n, MSG_DONTWAIT, (struct sockaddr *)&peer, plen); }
    }
  }
  return NULL;
}
