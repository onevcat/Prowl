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
        browsers = (builtins.fromJSON (builtins.readFile "${pkgs.playwright-driver}/browsers.json")).browsers;
        chromiumRevision = (builtins.head (builtins.filter (browser: browser.name == "chromium") browsers)).revision;
        chromiumExecutable =
          "${pkgs.playwright-driver.browsers}/chromium-${chromiumRevision}/chrome-linux64/chrome";
      in
      {
        devShells.default = pkgs.mkShell {
          packages = with pkgs; [
            bun
            playwright-driver.browsers
          ];

          shellHook = ''
            export PLAYWRIGHT_BROWSERS_PATH="${pkgs.playwright-driver.browsers}"
            export PLAYWRIGHT_LAUNCH_OPTIONS_EXECUTABLE_PATH="${chromiumExecutable}"
            export PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1
            export PLAYWRIGHT_SKIP_VALIDATE_HOST_REQUIREMENTS=true
          '';
        };
      }
    );
}
