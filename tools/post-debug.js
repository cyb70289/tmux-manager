// Posts a debug action to a TmuxManager instance launched with --debug.
// Usage: osascript -l JavaScript tools/post-debug.js <action> [value] [kill]
//   open|reconnect|remove <entry-uuid> [1]
//   add <entry-json>
//   sheet | closesheet | reload | capture | windows
//   sizebar <x> <y> <w> <h>
function run(argv) {
    ObjC.import('Foundation');
    const action = argv[0];
    if (!action) throw new Error('action required');
    const info = $.NSMutableDictionary.alloc.init;
    info.setObjectForKey(action, 'action');

    if (action === 'add' && argv[1]) info.setObjectForKey(argv[1], 'json');
    else if (action === 'sizebar') {
        ['x', 'y', 'w', 'h'].forEach(function (key, index) {
            info.setObjectForKey(argv[index + 1], key);
        });
    } else if (argv[1]) {
        info.setObjectForKey(argv[1], 'entry');
        if (argv[2]) info.setObjectForKey(argv[2], 'kill');
    }

    $.NSDistributedNotificationCenter.defaultCenter
        .postNotificationNameObjectUserInfoDeliverImmediately(
            'com.cyb.tmuxmanager.debug', $(), info, true);
    return 'posted ' + action;
}
