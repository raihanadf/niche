{
  description = "niche for KDE Plasma: a floating dynamic island";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      kde = pkgs.kdePackages;

      # Qt plugins and QML modules the app loads at runtime. They are baked into
      # the binary (see src/main.cpp) instead of a wrapper script, because KWin
      # grants the fake-input protocol by matching the desktop file's Exec path
      # against the real executable.
      runtime = with kde; [
        qtbase
        qtdeclarative
        qtwayland
        qtsvg
        layer-shell-qt
        # kirigami is a wrapper derivation that only propagates; the QML
        # module lives in the unwrapped output.
        kirigami.unwrapped
        qqc2-desktop-style
        kiconthemes
        kstatusnotifieritem
        kglobalaccel
        kguiaddons
        sonnet
      ];
      pluginPath = pkgs.lib.concatMapStringsSep ":" (p: "${p}/lib/qt-6/plugins") runtime;
      qmlPath = pkgs.lib.concatMapStringsSep ":" (p: "${p}/lib/qt-6/qml") runtime;

      buildInputs = runtime ++ (with pkgs; [ libpulseaudio glib wayland kde.plasma-wayland-protocols ]);
      nativeBuildInputs = with pkgs; [ cmake ninja pkg-config kde.extra-cmake-modules wayland-scanner ];
    in
    {
      packages.${system}.default = pkgs.stdenv.mkDerivation {
        pname = "niche-kde";
        version = "0.1.0";
        src = self;
        inherit buildInputs nativeBuildInputs;
        dontWrapQtApps = true;
        cmakeFlags = [
          "-DNICHE_PLUGIN_PATH=${pluginPath}"
          "-DNICHE_QML_PATH=${qmlPath}"
        ];
        meta.mainProgram = "niche-kde";
      };

      devShells.${system}.default = pkgs.mkShell {
        inherit buildInputs;
        nativeBuildInputs = nativeBuildInputs ++ [ pkgs.gdb ];
        NICHE_PLUGIN_PATH = pluginPath;
        NICHE_QML_PATH = qmlPath;
      };
    };
}
