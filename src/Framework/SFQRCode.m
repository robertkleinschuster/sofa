#import "SFQRCode.h"

// The standard's tables (ISO/IEC 18004 table 9), index = version; rows: L, M, Q, H
static const int8_t kECCPerBlock[4][41] = {
    {-1,  7, 10, 15, 20, 26, 18, 20, 24, 30, 18, 20, 24, 26, 30, 22, 24, 28, 30, 28, 28, 28, 28, 30, 30, 26, 28, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30},
    {-1, 10, 16, 26, 18, 24, 16, 18, 22, 22, 26, 30, 22, 22, 24, 24, 28, 28, 26, 26, 26, 26, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28},
    {-1, 13, 22, 18, 26, 18, 24, 18, 22, 20, 24, 28, 26, 24, 20, 30, 24, 28, 28, 26, 30, 28, 30, 30, 30, 30, 28, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30},
    {-1, 17, 28, 22, 16, 22, 28, 26, 26, 24, 28, 24, 28, 22, 24, 24, 30, 28, 28, 26, 28, 30, 24, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30},
};
static const int8_t kBlocks[4][41] = {
    {-1, 1, 1, 1, 1, 1, 2, 2, 2, 2,  4,  4,  4,  4,  4,  6,  6,  6,  6,  7,  8,  8,  9,  9, 10, 12, 12, 12, 13, 14, 15, 16, 17, 18, 19, 19, 20, 21, 22, 24, 25},
    {-1, 1, 1, 1, 2, 2, 4, 4, 4, 5,  5,  5,  8,  9,  9, 10, 10, 11, 13, 14, 16, 17, 17, 18, 20, 21, 23, 25, 26, 28, 29, 31, 33, 35, 37, 38, 40, 43, 45, 47, 49},
    {-1, 1, 1, 2, 2, 4, 4, 6, 6, 8,  8,  8, 10, 12, 16, 12, 17, 16, 18, 21, 20, 23, 23, 25, 27, 29, 34, 34, 35, 38, 40, 43, 45, 48, 51, 53, 56, 59, 62, 65, 68},
    {-1, 1, 1, 2, 4, 4, 4, 5, 6, 8,  8, 11, 11, 16, 16, 18, 16, 19, 21, 25, 25, 25, 34, 30, 32, 35, 37, 40, 42, 45, 48, 51, 54, 57, 60, 63, 66, 70, 74, 77, 81},
};
static const int kFormatBits[4] = {1, 0, 3, 2};   // L, M, Q, H as the format information names them

// Modules of a version that carry data and error correction (everything but the function patterns)
static int RawModules(int ver) {
    int n = (16 * ver + 128) * ver + 64;
    if (ver >= 2) { int align = ver / 7 + 2; n -= (25 * align - 10) * align - 55; if (ver >= 7) n -= 36; }
    return n;
}

static int DataCodewords(int ver, int ecc) { return RawModules(ver) / 8 - kECCPerBlock[ecc][ver] * kBlocks[ecc][ver]; }

#pragma mark Reed-Solomon over GF(256), x^8 + x^4 + x^3 + x^2 + 1

static uint8_t Mul(uint8_t x, uint8_t y) {
    int z = 0;
    for (int i = 7; i >= 0; i--) { z = (z << 1) ^ ((z >> 7) * 0x11D); z ^= ((y >> i) & 1) * x; }
    return (uint8_t)z;
}

static void Divisor(int degree, uint8_t *out) {
    memset(out, 0, (size_t)degree);
    out[degree - 1] = 1;
    uint8_t root = 1;
    for (int i = 0; i < degree; i++) {
        for (int j = 0; j < degree; j++) { out[j] = Mul(out[j], root); if (j + 1 < degree) out[j] ^= out[j + 1]; }
        root = Mul(root, 0x02);
    }
}

static void Remainder(const uint8_t *data, int len, const uint8_t *divisor, int degree, uint8_t *out) {
    memset(out, 0, (size_t)degree);
    for (int i = 0; i < len; i++) {
        uint8_t factor = data[i] ^ out[0];
        memmove(out, out + 1, (size_t)degree - 1);
        out[degree - 1] = 0;
        for (int j = 0; j < degree; j++) out[j] ^= Mul(divisor[j], factor);
    }
}

@implementation SFQRCode {
    NSMutableData *_dark, *_function;   // size * size, row-major
}

- (uint8_t *)m { return _dark.mutableBytes; }
- (uint8_t *)f { return _function.mutableBytes; }

- (BOOL)darkAtX:(NSInteger)x y:(NSInteger)y {
    if (x < 0 || y < 0 || x >= _size || y >= _size) return NO;
    return ((const uint8_t *)_dark.bytes)[y * _size + x] != 0;
}

- (void)setFunctionX:(NSInteger)x y:(NSInteger)y dark:(BOOL)dark {
    self.m[y * _size + x] = dark; self.f[y * _size + x] = 1;
}

+ (instancetype)codeForText:(NSString *)text ecc:(SFQRECC)wanted {
    NSData *bytes = [text dataUsingEncoding:NSUTF8StringEncoding];
    if (!bytes) return nil;
    int ecc = (int)wanted, ver = 0, used = 0;
    for (int v = 1; v <= 40; v++) {   // mode (4) + count (8 bits up to version 9, else 16) + the bytes
        used = 4 + (v <= 9 ? 8 : 16) + (int)bytes.length * 8;
        if (used <= DataCodewords(v, ecc) * 8) { ver = v; break; }
    }
    if (!ver || bytes.length > 0xFFFF) return nil;
    for (int e = ecc + 1; e <= SFQRECCHigh; e++) if (used <= DataCodewords(ver, e) * 8) ecc = e;   // more correction, same size
    SFQRCode *c = [SFQRCode new];
    c->_version = ver; c->_ecc = (SFQRECC)ecc; c->_size = 17 + 4 * ver;
    c->_dark = [NSMutableData dataWithLength:(NSUInteger)(c->_size * c->_size)];
    c->_function = [NSMutableData dataWithLength:(NSUInteger)(c->_size * c->_size)];
    [c drawFunctionPatterns];
    [c drawCodewords:[c codewordsFor:bytes]];
    [c chooseMask];
    return c;
}

#pragma mark Codewords

- (NSData *)codewordsFor:(NSData *)bytes {
    int ver = (int)_version, ecc = (int)_ecc, capacity = DataCodewords(ver, ecc);
    NSMutableData *bits = [NSMutableData dataWithLength:(NSUInteger)capacity];
    uint8_t *b = bits.mutableBytes;
    __block int n = 0;
    void (^put)(uint32_t, int) = ^(uint32_t value, int count) {
        for (int i = count - 1; i >= 0; i--, n++) if ((value >> i) & 1) b[n >> 3] |= (uint8_t)(0x80 >> (n & 7));
    };
    put(0x4, 4);   // byte mode
    put((uint32_t)bytes.length, ver <= 9 ? 8 : 16);
    for (NSUInteger i = 0; i < bytes.length; i++) put(((const uint8_t *)bytes.bytes)[i], 8);
    put(0, MIN(4, capacity * 8 - n));   // terminator
    n = (n + 7) / 8 * 8;
    for (int k = 0, padding = capacity - n / 8; k < padding; k++) put(k % 2 ? 0x11 : 0xEC, 8);
    // split into blocks, each with its error correction, then interleaved
    int blocks = kBlocks[ecc][ver], eccLen = kECCPerBlock[ecc][ver], raw = RawModules(ver) / 8;
    int shortBlocks = blocks - raw % blocks, shortLen = raw / blocks;
    uint8_t divisor[32], rem[32];
    Divisor(eccLen, divisor);
    NSMutableData *all = [NSMutableData dataWithLength:(NSUInteger)(blocks * (shortLen + 1))];   // every block as a long one
    uint8_t *a = all.mutableBytes;
    for (int i = 0, k = 0; i < blocks; i++) {
        int datLen = shortLen - eccLen + (i < shortBlocks ? 0 : 1);
        uint8_t *block = a + i * (shortLen + 1);
        memcpy(block, b + k, (size_t)datLen);
        Remainder(b + k, datLen, divisor, eccLen, rem);
        k += datLen;
        memcpy(block + shortLen + 1 - eccLen, rem, (size_t)eccLen);   // a short block's gap stays before its ECC
    }
    NSMutableData *out = [NSMutableData dataWithCapacity:(NSUInteger)raw];
    for (int i = 0; i <= shortLen; i++)
        for (int j = 0; j < blocks; j++)
            if (i != shortLen - eccLen || j >= shortBlocks) [out appendBytes:a + j * (shortLen + 1) + i length:1];
    return out;
}

#pragma mark Patterns

- (void)drawFinderAt:(NSInteger)cx y:(NSInteger)cy {
    for (int dy = -4; dy <= 4; dy++)
        for (int dx = -4; dx <= 4; dx++) {
            NSInteger x = cx + dx, y = cy + dy;
            int dist = MAX(abs(dx), abs(dy));
            if (x >= 0 && y >= 0 && x < _size && y < _size) [self setFunctionX:x y:y dark:dist != 2 && dist != 4];
        }
}

- (void)drawFunctionPatterns {
    for (NSInteger i = 0; i < _size; i++) { [self setFunctionX:6 y:i dark:i % 2 == 0]; [self setFunctionX:i y:6 dark:i % 2 == 0]; }
    [self drawFinderAt:3 y:3]; [self drawFinderAt:_size - 4 y:3]; [self drawFinderAt:3 y:_size - 4];
    if (_version > 1) {
        int count = (int)_version / 7 + 2;
        int step = _version == 32 ? 26 : ((int)_version * 4 + count * 2 + 1) / (count * 2 - 2) * 2;
        NSInteger pos[7]; pos[0] = 6;
        for (int i = count - 1, p = (int)_size - 7; i >= 1; i--, p -= step) pos[i] = p;
        for (int i = 0; i < count; i++)
            for (int j = 0; j < count; j++) {
                if ((i == 0 && j == 0) || (i == 0 && j == count - 1) || (i == count - 1 && j == 0)) continue;   // the finders' corners
                for (int dy = -2; dy <= 2; dy++)
                    for (int dx = -2; dx <= 2; dx++) [self setFunctionX:pos[i] + dx y:pos[j] + dy dark:MAX(abs(dx), abs(dy)) != 1];
            }
    }
    [self drawFormat:0];   // reserved now, written with the mask
    if (_version >= 7) {
        uint32_t rem = (uint32_t)_version;
        for (int i = 0; i < 12; i++) rem = (rem << 1) ^ ((rem >> 11) * 0x1F25);
        uint32_t bits = (uint32_t)_version << 12 | rem;
        for (int i = 0; i < 18; i++) {
            BOOL bit = (bits >> i) & 1;
            NSInteger a = _size - 11 + i % 3, b = i / 3;
            [self setFunctionX:a y:b dark:bit]; [self setFunctionX:b y:a dark:bit];
        }
    }
}

- (void)drawFormat:(NSInteger)mask {
    uint32_t data = (uint32_t)(kFormatBits[_ecc] << 3 | mask), rem = data;
    for (int i = 0; i < 10; i++) rem = (rem << 1) ^ ((rem >> 9) * 0x537);
    uint32_t bits = (data << 10 | rem) ^ 0x5412;
    #define BIT(i) (((bits >> (i)) & 1) != 0)
    for (int i = 0; i <= 5; i++) [self setFunctionX:8 y:i dark:BIT(i)];
    [self setFunctionX:8 y:7 dark:BIT(6)]; [self setFunctionX:8 y:8 dark:BIT(7)]; [self setFunctionX:7 y:8 dark:BIT(8)];
    for (int i = 9; i < 15; i++) [self setFunctionX:14 - i y:8 dark:BIT(i)];
    for (int i = 0; i < 8; i++) [self setFunctionX:_size - 1 - i y:8 dark:BIT(i)];
    for (int i = 8; i < 15; i++) [self setFunctionX:8 y:_size - 15 + i dark:BIT(i)];
    #undef BIT
    [self setFunctionX:8 y:_size - 8 dark:YES];   // always dark
}

// The codewords in the standard's zigzag: two columns at a time from the right, up and down
- (void)drawCodewords:(NSData *)data {
    const uint8_t *d = data.bytes;
    NSUInteger i = 0, total = data.length * 8;
    for (NSInteger right = _size - 1; right >= 1; right -= 2) {
        if (right == 6) right = 5;   // the vertical timing pattern
        for (NSInteger vert = 0; vert < _size; vert++)
            for (int j = 0; j < 2; j++) {
                NSInteger x = right - j;
                BOOL upward = ((right + 1) & 2) == 0;
                NSInteger y = upward ? _size - 1 - vert : vert;
                if (!self.f[y * _size + x] && i < total) { self.m[y * _size + x] = (d[i >> 3] >> (7 - (i & 7))) & 1; i++; }
            }
    }
}

#pragma mark Masks

static BOOL Masked(NSInteger mask, NSInteger x, NSInteger y) {
    switch (mask) {
        case 0: return (x + y) % 2 == 0;
        case 1: return y % 2 == 0;
        case 2: return x % 3 == 0;
        case 3: return (x + y) % 3 == 0;
        case 4: return (x / 3 + y / 2) % 2 == 0;
        case 5: return x * y % 2 + x * y % 3 == 0;
        case 6: return (x * y % 2 + x * y % 3) % 2 == 0;
        default: return ((x + y) % 2 + x * y % 3) % 2 == 0;
    }
}

- (void)applyMask:(NSInteger)mask {   // its own inverse
    for (NSInteger y = 0; y < _size; y++)
        for (NSInteger x = 0; x < _size; x++)
            if (!self.f[y * _size + x] && Masked(mask, x, y)) self.m[y * _size + x] ^= 1;
}

- (void)chooseMask {
    long best = LONG_MAX; NSInteger chosen = 0;
    for (NSInteger mask = 0; mask < 8; mask++) {
        [self applyMask:mask]; [self drawFormat:mask];
        long p = [self penalty];
        if (p < best) { best = p; chosen = mask; }
        [self applyMask:mask];
    }
    _mask = chosen;
    [self applyMask:chosen]; [self drawFormat:chosen];
}

// Finder-like runs (1:1:3:1:1 with 4 light on a side): the last 7 run lengths, newest first
static void AddRun(int run, int *history, int size) {
    if (history[0] == 0) run += size;   // the light border before the first run
    memmove(history + 1, history, 6 * sizeof(int));
    history[0] = run;
}

static int CountFinderLike(const int *h) {
    int n = h[1];
    BOOL core = n > 0 && h[2] == n && h[3] == n * 3 && h[4] == n && h[5] == n;
    return (core && h[0] >= n * 4 && h[6] >= n ? 1 : 0) + (core && h[6] >= n * 4 && h[0] >= n ? 1 : 0);
}

- (long)penaltyOfLine:(BOOL)rows index:(NSInteger)k {
    long p = 0;
    int history[7] = {0}, size = (int)_size, run = 0;
    BOOL color = NO;
    for (NSInteger i = 0; i < _size; i++) {
        BOOL dark = rows ? [self darkAtX:i y:k] : [self darkAtX:k y:i];
        if (dark == color) {
            run++;
            if (run == 5) p += 3; else if (run > 5) p++;
        } else {
            AddRun(run, history, size);
            if (!color) p += CountFinderLike(history) * 40;
            color = dark; run = 1;
        }
    }
    if (color) { AddRun(run, history, size); run = 0; }   // the line ends in the light border
    AddRun(run + size, history, size);
    return p + CountFinderLike(history) * 40;
}

- (long)penalty {
    long p = 0, dark = 0;
    for (NSInteger k = 0; k < _size; k++) p += [self penaltyOfLine:YES index:k] + [self penaltyOfLine:NO index:k];
    for (NSInteger y = 0; y < _size; y++)
        for (NSInteger x = 0; x < _size; x++) {
            BOOL c = [self darkAtX:x y:y];
            dark += c;
            if (x < _size - 1 && y < _size - 1 && c == [self darkAtX:x + 1 y:y] && c == [self darkAtX:x y:y + 1] && c == [self darkAtX:x + 1 y:y + 1]) p += 3;
        }
    long total = _size * _size;
    long k = (labs(dark * 20 - total * 10) + total - 1) / total - 1;   // 5 % steps away from half dark
    return p + k * 10;
}

#pragma mark Image

- (CGImageRef)newImageWithQuietZone:(NSInteger)quiet dark:(CGColorRef)darkColor light:(CGColorRef)lightColor {
    size_t side = (size_t)(_size + 2 * quiet);
    CGColorSpaceRef rgb = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(NULL, side, side, 8, side * 4, rgb, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(rgb);
    if (!ctx) return NULL;
    CGContextSetFillColorWithColor(ctx, lightColor);
    CGContextFillRect(ctx, CGRectMake(0, 0, side, side));
    CGContextSetFillColorWithColor(ctx, darkColor);
    for (NSInteger y = 0; y < _size; y++)   // the bitmap's origin is bottom left
        for (NSInteger x = 0; x < _size; x++)
            if ([self darkAtX:x y:y]) CGContextFillRect(ctx, CGRectMake(quiet + x, (CGFloat)side - 1 - (quiet + y), 1, 1));
    CGImageRef img = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    return img;
}
@end
