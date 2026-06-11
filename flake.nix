{
  description = "OpenScreenshot — open-source screenshot, recording and annotation tool for macOS";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  outputs = { self, nixpkgs }:
    let
      systems = [ "aarch64-darwin" "x86_64-darwin" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      packages = forAllSystems (pkgs: rec {
        default = openscreenshot;

        # Packages the (universal) release artifact: building Swift +
        # ScreenCaptureKit inside the Nix sandbox isn't practical, and using
        # the published zip keeps the app's code signature intact, which the
        # Screen Recording permission depends on.
        openscreenshot = pkgs.stdenvNoCC.mkDerivation (finalAttrs: {
          pname = "openscreenshot";
          # version and hash are updated automatically by the release workflow.
          version = "0.0.0";

          src = pkgs.fetchurl {
            url = "https://github.com/ostoolkit/openscreenshot/releases/download/v${finalAttrs.version}/OpenScreenshot-v${finalAttrs.version}.zip";
            hash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
          };

          nativeBuildInputs = [ pkgs.unzip ];
          sourceRoot = ".";

          # Don't touch the bundle: patching/stripping would invalidate the
          # signature and reset TCC permission grants.
          dontPatch = true;
          dontConfigure = true;
          dontBuild = true;
          dontFixup = true;

          installPhase = ''
            runHook preInstall
            mkdir -p $out/Applications
            cp -R OpenScreenshot.app $out/Applications/
            runHook postInstall
          '';

          meta = with pkgs.lib; {
            description = "Open-source screenshot, screen recording and annotation tool for macOS";
            homepage = "https://github.com/ostoolkit/openscreenshot";
            license = licenses.mit;
            platforms = platforms.darwin;
            sourceProvenance = with sourceTypes; [ binaryNativeCode ];
          };
        });
      });

      overlays.default = final: prev: {
        openscreenshot = self.packages.${final.stdenv.hostPlatform.system}.openscreenshot;
      };
    };
}
