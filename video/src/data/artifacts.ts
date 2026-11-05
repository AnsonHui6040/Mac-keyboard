/**
 * The two release files of the tutorial, their SHA-256 values and the public addresses shown in the browser windows.
 * Everything here is real and public: the file names and SHA-256 values are the ones on the v0.1.0-b2 Release page, which
 * testers compare their own download against. The film is tied to that release and goes stale at the next one.
 * Only the folder (`~/Downloads`) and the verification code of scene 5 are made up. Written in the project so the build never goes online.
 */
export const VERSION = '0.1.0';
export const IPA_NAME = `RemoteKeyboard-v${VERSION}-unsigned.ipa`;
export const ZIP_NAME = `RemoteKeyboardReceiver-v${VERSION}-macOS.zip`;
export const IPA_SHA256 = 'e66d8a72cf6d7f3533e5ce22afdb8f78154f94c9aecfac62b0463444e966753f';
export const ZIP_SHA256 = 'f9b5f22650539eab6def4bdcae8247763ff13d6325946f22d413fe3b5c40854a';
export const DOWNLOADS = '~/Downloads';
/** Address bar of the Release page (scenes 10 and 15), of the iloader download page (scene 5), and the repository shown in scene 21. */
export const RELEASE_URL = 'github.com/AnsonHui6040/Mac-keyboard/releases/tag/v0.1.0-b2';
export const SIDESTORE_URL = 'sidestore.io';
export const REPO_URL = 'github.com/AnsonHui6040/Mac-keyboard';
/** Fictional six-digit verification code typed into the iloader sheet of scene 5. It is not the pairing code of scenes 18 and 19. */
export const SIGNIN_CODE = '607143';
