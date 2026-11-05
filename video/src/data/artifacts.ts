/**
 * The two release files of the tutorial, their SHA-256 values and the public addresses shown in the browser windows.
 * Everything here is real and public: the file names and SHA-256 values are the ones on the v0.1.0-alpha.1 Release page, which
 * testers compare their own download against. The film is tied to that release and goes stale at the next one.
 * Only the folder (`~/Downloads`) and the verification code of scene 5 are made up. Written in the project so the build never goes online.
 */
export const VERSION = '0.1.0';
export const IPA_NAME = `RemoteKeyboard-v${VERSION}-unsigned.ipa`;
export const ZIP_NAME = `RemoteKeyboardReceiver-v${VERSION}-macOS.zip`;
export const IPA_SHA256 = 'd4b5531ca5d971cef89f8488e020421bff3d224d3f00faed38ce1ca08b1558db';
export const ZIP_SHA256 = '21dd6a41f0b72b4370378c9dbcd29f2d2172c24b0232713e358b0a5e129c6ec9';
export const DOWNLOADS = '~/Downloads';
/** Address bar of the Release page (scenes 10 and 15), of the iloader download page (scene 5), and the repository shown in scene 21. */
export const RELEASE_URL = 'github.com/AnsonHui6040/Mac-keyboard/releases/tag/v0.1.0-alpha.1';
export const SIDESTORE_URL = 'sidestore.io';
export const REPO_URL = 'github.com/AnsonHui6040/Mac-keyboard';
/** Fictional six-digit verification code typed into the iloader sheet of scene 5. It is not the pairing code of scenes 18 and 19. */
export const SIGNIN_CODE = '607143';
