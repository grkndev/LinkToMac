/**
 * Where the project lives. One place so About, the update checker and the Diagnostics screen
 * can't disagree. (The native `AppUpdater.kt` keeps its own copy of the releases feed URL — it
 * can't import from JS — so change both if the repo ever moves.)
 */
export const REPO_SLUG = 'grkndev/LinkToMac';
export const REPO_URL = `https://github.com/${REPO_SLUG}`;
export const RELEASES_URL = `${REPO_URL}/releases`;
export const NEW_ISSUE_URL = `${REPO_URL}/issues/new`;
export const LATEST_RELEASE_API = `https://api.github.com/repos/${REPO_SLUG}/releases/latest`;

export const PROFILE_URL = 'https://grkn.dev';
export const CONTACT_EMAIL = 'info@grkn.dev';
