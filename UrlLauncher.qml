import QtQml

// Opens JobHunt pages. The host is fixed: a link that came out of JobHunt data
// is only opened if it is on https://jobhunt.app, so data cannot pick another site.
QtObject {
  property string linkBehavior: "Browser tab"

  signal browserLaunchRequested(var argv)
  signal webAppLaunchRequested(var argv)

  function isAllowedUrl(url) {
    // No whitespace or quote characters at all; the path is plain URL characters.
    return /^https:\/\/jobhunt[.]app(?:\/[A-Za-z0-9\-._~\/%?=&#]*)?$/.test(String(url || ""))
  }

  function openUrl(url) {
    var value = String(url || "")
    if (!isAllowedUrl(value)) return false
    if (linkBehavior === "Web app window")
      webAppLaunchRequested(["omarchy-launch-webapp", value])
    else
      browserLaunchRequested(["xdg-open", value])
    return true
  }
}
