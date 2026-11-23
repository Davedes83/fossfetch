// CategoryModel.js — pure logic for category browsing, extracted so it can be unit-tested.
// Mirrors Model.js conventions: ES5, no QML deps, pure functions.

// Hard-coded mirror of groups.keywords so the sidebar works without filesystem access at runtime.
// Keep in sync with groups.keywords (tools/sync_categories.sh can verify).
var CATEGORY_KEYWORDS = {
    "WebBrowser": ["browser", "web"],
    "AudioVideoEditing": ["video editing", "video editor", "editing", "editor"],
    "Video": ["video", "movie"],
    "Audio": ["audio", "sound"],
    "Music": ["music"],
    "Player": ["player", "music"],
    "Photography": ["photo", "photos", "picture", "pictures", "image", "camera"],
    "Graphics": ["graphic", "graphics", "draw", "paint"],
    "Chat": ["chat", "messaging", "message", "discord", "telegram", "signal"],
    "InstantMessaging": ["messaging"],
    "TerminalEmulator": ["terminal", "console", "shell"],
    "TextEditor": ["editor", "code editor", "text editor", "text"],
    "Development": ["ide", "development", "programming", "code editor"],
    "WordProcessor": ["word"],
    "Office": ["office", "document", "documents", "word"],
    "Spreadsheet": ["spreadsheet", "spreadsheets", "calc", "sheets"],
    "Presentation": ["presentation", "slides"],
    "Finance": ["finance", "money", "banking", "accounting"],
    "Game": ["game", "games", "gaming"],
    "StrategyGame": ["strategy"],
    "ActionGame": ["action"],
    "LogicGame": ["puzzle"],
    "BoardGame": ["board", "chess"],
    "RacingGame": ["racing"],
    "SportsGame": ["sports"],
    "RolePlaying": ["rpg"],
    "Email": ["email", "mail"],
    "Calendar": ["calendar"],
    "FileManager": ["file manager", "filemanager"],
    "Archiving": ["archive", "archiving", "backup", "compression", "zip", "tar"],
    "Viewer": ["viewer", "reader"],
    "Scanning": ["scan", "scanning", "scanner"],
    "OCR": ["ocr"],
    "P2P": ["torrent", "torrents"],
    "FileTransfer": ["download", "downloader"],
    "Network": ["network", "networking"],
    "Security": ["security", "password", "password manager", "privacy", "vpn"],
    "Science": ["science", "math", "chemistry", "physics", "astronomy"],
    "Education": ["education", "study"],
    "Database": ["database", "database manager"],
    "Monitor": ["monitor", "system monitor", "monitoring"],
    "System": ["system", "tools", "utility"],
    "Settings": ["settings", "preferences", "config"],
    "RemoteAccess": ["remote", "vnc"],
    "VideoConference": ["meeting", "video conference"],
    "Maps": ["maps"],
    "News": ["news"],
    "Feed": ["rss"]
};

// Human-readable labels for categories (AppStream ID -> display name)
var CATEGORY_LABELS = {
    "WebBrowser": "Web Browser",
    "AudioVideoEditing": "Video Editing",
    "Video": "Video",
    "Audio": "Audio",
    "Music": "Music",
    "Player": "Media Player",
    "Photography": "Photography",
    "Graphics": "Graphics & Design",
    "Chat": "Chat & Messaging",
    "InstantMessaging": "Instant Messaging",
    "TerminalEmulator": "Terminal",
    "TextEditor": "Text Editor",
    "Development": "Development",
    "WordProcessor": "Word Processor",
    "Office": "Office",
    "Spreadsheet": "Spreadsheet",
    "Presentation": "Presentation",
    "Finance": "Finance",
    "Game": "Games",
    "StrategyGame": "Strategy Games",
    "ActionGame": "Action Games",
    "LogicGame": "Puzzle Games",
    "BoardGame": "Board Games",
    "RacingGame": "Racing Games",
    "SportsGame": "Sports Games",
    "RolePlaying": "RPG",
    "Email": "Email",
    "Calendar": "Calendar",
    "FileManager": "File Manager",
    "Archiving": "Archiving",
    "Viewer": "Viewer",
    "Scanning": "Scanning",
    "OCR": "OCR",
    "P2P": "BitTorrent",
    "FileTransfer": "Download Manager",
    "Network": "Network Tools",
    "Security": "Security & Privacy",
    "Science": "Science",
    "Education": "Education",
    "Database": "Database",
    "Monitor": "System Monitor",
    "System": "System Tools",
    "Settings": "Settings",
    "RemoteAccess": "Remote Access",
    "VideoConference": "Video Conference",
    "Maps": "Maps",
    "News": "News",
    "Feed": "RSS/Feed Reader"
};

// Material Design icon codepoints (surrogate pairs) for each category
var CATEGORY_ICONS = {
    "WebBrowser": "\uDB80\uDF4C",        // web
    "AudioVideoEditing": "\uDB80\uDD8E", // video
    "Video": "\uDB80\uDD8E",             // video
    "Audio": "\uDB80\uDD8C",             // music-note
    "Music": "\uDB80\uDD8C",             // music-note
    "Player": "\uDB81\uDD49",            // play-circle-outline
    "Photography": "\uDB80\uDDF7",       // camera
    "Graphics": "\uDB81\uDDD8",          // palette
    "Chat": "\uDB80\uDEDC",              // message
    "InstantMessaging": "\uDB80\uDEDC",  // message
    "TerminalEmulator": "\uDB80\uDD7D",  // console
    "TextEditor": "\uDB80\uDE3D",        // file-document
    "Development": "\uDB80\uDDC5",       // code-tags
    "WordProcessor": "\uDB80\uDE3D",     // file-document
    "Office": "\uDB80\uDE3B",            // file-document-outline
    "Spreadsheet": "\uDB80\uDE3C",       // file-spreadsheet
    "Presentation": "\uDB80\uDE3E",      // file-presentation-box
    "Finance": "\uDB80\uDD3A",           // currency-usd
    "Game": "\uDB80\uDDA7",              // cube-outline
    "StrategyGame": "\uDB80\uDDA7",      // cube-outline
    "ActionGame": "\uDB80\uDDA7",        // cube-outline
    "LogicGame": "\uDB80\uDDA7",         // cube-outline
    "BoardGame": "\uDB80\uDDA7",         // cube-outline
    "RacingGame": "\uDB80\uDDA7",        // cube-outline
    "SportsGame": "\uDB80\uDDA7",        // cube-outline
    "RolePlaying": "\uDB80\uDDA7",       // cube-outline
    "Email": "\uDB80\uDEFA",             // email
    "Calendar": "\uDB80\uDD50",          // clock-outline
    "FileManager": "\uDB80\uDFD7",       // package-variant-closed
    "Archiving": "\uDB80\uDD62",         // archive
    "Viewer": "\uDB80\uDEFD",            // information-outline
    "Scanning": "\uDB80\uDD56",          // scanner
    "OCR": "\uDB80\uDE3D",               // file-document
    "P2P": "\uDB81\uDE2C",               // source-branch
    "FileTransfer": "\uDB80\uDDDA",      // download
    "Network": "\uDB80\uDF10",           // lan
    "Security": "\uDB83\uDCC8",          // shield-check-outline
    "Science": "\uDB80\uDDD5",           // flask
    "Education": "\uDB80\uDDD6",         // school
    "Database": "\uDB80\uDDA0",          // database
    "Monitor": "\uDB80\uDE8A",           // monitor
    "System": "\uDB80\uDE8A",            // monitor
    "Settings": "\uDB82\uDCBB",          // cog-outline
    "RemoteAccess": "\uDB80\uDF10",      // lan
    "VideoConference": "\uDB80\uDD8E",   // video
    "Maps": "\uDB80\uDF01",              // map
    "News": "\uDB80\uDE3B",              // file-document-outline
    "Feed": "\uDB81\uDD4B"               // rss
};

// Return all category IDs sorted alphabetically by label
function categoryIds() {
    var ids = Object.keys(CATEGORY_LABELS);
    ids.sort(function(a, b) {
        var la = CATEGORY_LABELS[a] || a;
        var lb = CATEGORY_LABELS[b] || b;
        return la.localeCompare(lb);
    });
    return ids;
}

// Get display label for a category ID
function categoryLabel(id) {
    return CATEGORY_LABELS[id] || id;
}

// Get icon for a category ID
function categoryIcon(id) {
    return CATEGORY_ICONS[id] || "\uDB80\uDF49"; // fallback: magnify
}

// Get keywords for a category ID (for tooltip/search hints)
function categoryKeywords(id) {
    return CATEGORY_KEYWORDS[id] || [];
}

// Build the full category list for the sidebar model
// Returns array of { id, label, icon, keywords }
function categoryList() {
    var ids = categoryIds();
    var out = [];
    for (var i = 0; i < ids.length; i++) {
        var id = ids[i];
        out.push({
            id: id,
            label: categoryLabel(id),
            icon: categoryIcon(id),
            keywords: categoryKeywords(id).join(", ")
        });
    }
    return out;
}

// Search categories by label or keyword (case-insensitive substring)
function searchCategories(query) {
    var q = String(query || "").toLowerCase().trim();
    if (!q) return categoryList();
    var all = categoryList();
    var out = [];
    for (var i = 0; i < all.length; i++) {
        var c = all[i];
        var labelMatch = c.label.toLowerCase().indexOf(q) >= 0;
        var keywordMatch = c.keywords.toLowerCase().indexOf(q) >= 0;
        if (labelMatch || keywordMatch) out.push(c);
    }
    return out;
}

if (typeof module !== "undefined" && module.exports) {
    module.exports = {
        categoryIds: categoryIds,
        categoryLabel: categoryLabel,
        categoryIcon: categoryIcon,
        categoryKeywords: categoryKeywords,
        categoryList: categoryList,
        searchCategories: searchCategories
    };
}