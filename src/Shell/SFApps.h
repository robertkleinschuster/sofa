// The apps of the Sofa product and its own theme. The ONLY place that names app classes
// (docs/architecture.md): everything else asks SFAppRegistry.
#import "SFApp.h"

void SFRegisterApps(void);   // once, before the first SFTheme lookup (themes are cached)
