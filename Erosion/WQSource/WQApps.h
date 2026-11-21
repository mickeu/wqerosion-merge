#import <UIKit/UIKit.h>

// Reapplies the pre-restore safety state after an interrupted restore.
// Call on the serial I/O queue before presenting the result to the user.
NSString *_Nullable wq_recover_interrupted_restore(void);

@interface WQAppsViewController : UITableViewController <UISearchResultsUpdating>
// Opens Apps and, once the list is read, offers to restore this app's backup
// (from the App Backups long-press menu).
- (nonnull instancetype)initRestoringBundleID:(nonnull NSString *)bundleID;
@end

// MCP-facing app container operations. Each resolves the live container for
// the bundle id, then runs the same code path as the Apps screen. Return a
// result dictionary, or nil with *errorText set. Clear and restore always make
// a safety backup first; nothing is purged if it fails.
NSDictionary *_Nullable WQMCPAppBackup(NSString *bundleID, NSString *_Nullable *_Nullable errorText);
NSDictionary *_Nullable WQMCPAppClear(NSString *bundleID, BOOL safetyBackup, NSString *_Nullable *_Nullable errorText);
NSDictionary *_Nullable WQMCPAppRestore(NSString *bundleID, NSString *_Nullable backupName, NSString *_Nullable *_Nullable errorText);
