{
  description = "Prowl Web development shell";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    {
      nixpkgs,
      flake-utils,
      ...
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs { inherit system; };
        playwrightBrowsers = pkgs.playwright-driver.browsers.override {
          withChromium = true;
          withChromiumHeadlessShell = false;
          withFfmpeg = false;
          withFirefox = false;
          withWebkit = false;
        };
        browsers = (builtins.fromJSON (builtins.readFile "${pkgs.playwright-driver}/browsers.json")).browsers;
        chromiumRevision = (builtins.head (builtins.filter (browser: browser.name == "chromium") browsers)).revision;
        chromiumExecutable = "${playwrightBrowsers}/chromium-${chromiumRevision}/chrome-linux64/chrome";
      in
      {
        devShells.default = pkgs.mkShell {
          packages = with pkgs; [
            bun
            playwrightBrowsers
          ];

          shellHook = ''
            export PLAYWRIGHT_BROWSERS_PATH="${playwrightBrowsers}"
            export PLAYWRIGHT_LAUNCH_OPTIONS_EXECUTABLE_PATH="${chromiumExecutable}"
            export PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1
            export PLAYWRIGHT_SKIP_VALIDATE_HOST_REQUIREMENTS=true
          '';
        };
      }
    );
}
