/// <reference types="node" />
// Capacitor 8 configuration.
//
// The website build is untouched by this file. The iPhone app is built with
// `bun run build:ios`, which emits a static bundle into `dist-ios/` — that is
// the directory Capacitor copies into the Xcode project.
//
// On the Mac: bun run build:ios && npx cap add ios && npx cap sync ios
//
// The @capacitor/cli types are only installed on the Mac, so this file is kept
// dependency-free on purpose.
type CapacitorConfig = {
  appId: string;
  appName: string;
  webDir: string;
  ios?: Record<string, unknown>;
  server?: Record<string, unknown>;
  plugins?: Record<string, unknown>;
};

const config: CapacitorConfig = {
  appId: "app.lovable.teleprompter",
  appName: "Swegukin Teleprompter",
  webDir: "dist-ios",
  ios: {
    // The native camera preview renders behind the WebView, so the WebView
    // itself must be able to show through it.
    backgroundColor: "#00000000",
    webContentsDebuggingEnabled: true,
    contentInset: "never",
    limitsNavigationsToAppBoundDomains: true,
    // Media capture must never open a system player or require a tap.
    allowsInlineMediaPlayback: true,
  },
  plugins: {
    Keyboard: {
      // Never resize the teleprompter viewport when the editor keyboard opens.
      resize: "none",
      resizeOnFullScreen: false,
    },
  },
};

export default config;
