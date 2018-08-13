#import <dlfcn.h>

#define dylibDir        @"/usr/lib/tweaks"
#define safeModePath     "/usr/lib/MeridianSafeMode.dylib"

BOOL safeMode = false;

%group SpringBoard

%hook SBApplicationInfo
- (NSDictionary *)environmentVariables {
    NSDictionary *originalEnv = %orig;

    NSMutableDictionary *envVars = [originalEnv mutableCopy] ?: [NSMutableDictionary dictionary];

    NSString *offOrOn = safeMode ? @"1" : @"0";
    [envVars setObject:offOrOn forKey:@"_SafeMode"];
    [envVars setObject:offOrOn forKey:@"_MSSafeMode"];

    return envVars;
}
%end

%end

NSArray *generateDylibList() {
    NSString *processName = [[NSProcessInfo processInfo] processName];
    // launchctl, amfid you are special cases
    if ([processName isEqualToString:@"launchctl"]) {
        return nil;
    }
    if ([processName isEqualToString:@"amfid"]) {
        return nil;
    }
    // Create an array containing all the filenames in dylibDir
    NSError *e = nil;
    NSArray *dylibDirContents = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dylibDir error:&e];
    if (e) {
        return nil;
    }
    // Read current bundle identifier
    //NSString *bundleIdentifier = NSBundle.mainBundle.bundleIdentifier;
    // We're only interested in the plist files
    NSArray *plists = [dylibDirContents filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"SELF ENDSWITH %@", @"plist"]];
    // Create an empty mutable array that will contain a list of dylib paths to be injected into the target process
    NSMutableArray *dylibsToInject = [NSMutableArray array];
    // Loop through the list of plists
    for (NSString *plist in plists) {
        // We'll want to deal with absolute paths, so append the filename to dylibDir
        NSString *plistPath = [dylibDir stringByAppendingPathComponent:plist];
        NSDictionary *filter = [NSDictionary dictionaryWithContentsOfFile:plistPath];
        // This boolean indicates whether or not the dylib has already been injected
        BOOL isInjected = NO;
        // If supported iOS versions are specified within the plist, we check those first
        NSArray *supportedVersions = filter[@"CoreFoundationVersion"];
        if (supportedVersions) {
            if (supportedVersions.count != 1 && supportedVersions.count != 2) {
                continue; // Supported versions are in the wrong format, we should skip
            }
            if (supportedVersions.count == 1 && [supportedVersions[0] doubleValue] > kCFCoreFoundationVersionNumber) {
                continue; // Doesn't meet lower bound
            }
            if (supportedVersions.count == 2 && ([supportedVersions[0] doubleValue] > kCFCoreFoundationVersionNumber || [supportedVersions[1] doubleValue] <= kCFCoreFoundationVersionNumber)) {
                continue; // Outside bounds
            }
        }
        // Decide whether or not to load the dylib based on the Bundles values
        for (NSString *entry in filter[@"Filter"][@"Bundles"]) {
            // Check to see whether or not this bundle is actually loaded in this application or not
            if (!CFBundleGetBundleWithIdentifier((CFStringRef)entry)) {
                // If not, skip it
                continue;
            }
            [dylibsToInject addObject:[[plistPath stringByDeletingPathExtension] stringByAppendingString:@".dylib"]];
            isInjected = YES;
            break;
        }
        if (!isInjected) {
            // Decide whether or not to load the dylib based on the Executables values
            for (NSString *process in filter[@"Filter"][@"Executables"]) {
                if ([process isEqualToString:processName]) {
                    [dylibsToInject addObject:[[plistPath stringByDeletingPathExtension] stringByAppendingString:@".dylib"]];
                    isInjected = YES;
                    break;
                }
            }
        }
        if (!isInjected) {
            // Decide whether or not to load the dylib based on the Classes values
            for (NSString *clazz in filter[@"Filter"][@"Classes"]) {
                // Also check if this class is loaded in this application or not
                if (!NSClassFromString(clazz)) {
                    // This class couldn't be loaded, skip
                    continue;
                }
                // It's fine to add this dylib at this point
                [dylibsToInject addObject:[[plistPath stringByDeletingPathExtension] stringByAppendingString:@".dylib"]];
                isInjected = YES;
                break;
            }
        }
    }
    [dylibsToInject sortUsingSelector:@selector(caseInsensitiveCompare:)];
    return dylibsToInject;
}

void SpringBoardSigHandler(int signo, siginfo_t *info, void *uap){
    NSLog(@"Received signal %d", signo);

    FILE *f = fopen("/var/mobile/.safeMode", "w");
    fprintf(f, "Hello World\n");
    fclose(f);

    raise(signo);
}

int file_exist(char *filename) {
    return (access(filename, F_OK) == 0);
}

__attribute__ ((constructor))
static void ctor(void) {
    @autoreleasepool {
        safeMode = false;

        NSBundle *mainBundle = NSBundle.mainBundle;
        if (mainBundle != nil) {
            NSString *bundleID = mainBundle.bundleIdentifier;

            BOOL isSpringBoard = bundleID != NULL && [bundleID isEqualToString:@"com.apple.springboard"];
            if (isSpringBoard) {
                %init(SpringBoard);
            }
            
            if ([bundleID isEqualToString:@"com.apple.backboardd"] || isSpringBoard) {
                // Register the signal handler
                struct sigaction action;
                memset(&action, 0, sizeof(action));
                action.sa_sigaction = &SpringBoardSigHandler;
                action.sa_flags = SA_SIGINFO | SA_RESETHAND;
                sigemptyset(&action.sa_mask);

                sigaction(SIGQUIT, &action, NULL);
                sigaction(SIGILL, &action, NULL);
                sigaction(SIGTRAP, &action, NULL);
                sigaction(SIGABRT, &action, NULL);
                sigaction(SIGEMT, &action, NULL);
                sigaction(SIGFPE, &action, NULL);
                sigaction(SIGBUS, &action, NULL);
                sigaction(SIGSEGV, &action, NULL);
                sigaction(SIGSYS, &action, NULL);

                if (file_exist("/var/mobile/.safeMode")) {
                    safeMode = true;
                    if (isSpringBoard) {
                        unlink("/var/mobile/.safeMode");
                        //NSLog(@"Entering Safe Mode!");
                        void *dl = dlopen(safeModePath, RTLD_LAZY | RTLD_GLOBAL);

                        if (dl == NULL) {
                            //NSLog(@"FAILED TO LOAD SAFE MODE! This is a fatal error!");
                        }
                    }
                }
            }
        }
        
        const char *safeModeEnv   = getenv("_SafeMode");
        const char *msSafeModeEnv = getenv("_MSSafeMode");
        if ((safeModeEnv   != NULL && !strcmp(safeModeEnv, "1")) ||
            (msSafeModeEnv != NULL && !strcmp(msSafeModeEnv, "1"))) {
            safeMode = true;
        }
        
        if (!safeMode) {
            for (NSString *dylib in generateDylibList()) {
                void *dl = dlopen([dylib UTF8String], RTLD_LAZY | RTLD_GLOBAL);

                if (dl == NULL) {
                    NSLog(@"Injection failed: '%s'", dlerror());
                }
            }
        }
    }
}
