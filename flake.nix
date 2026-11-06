{
  description = "Unsloth: fast LLM finetuning, plus the Unsloth Studio web UI and CLI";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs =
    { self, nixpkgs }:
    let
      lib = nixpkgs.lib;
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];
      forAllSystems = f: lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});

      # Read the version from the same place setuptools does (unsloth/_version.py).
      version =
        let
          m = builtins.match ''.*__version__ = "([^"]+)".*'' (builtins.readFile ./unsloth/_version.py);
        in
        if m == null then "0.0.0" else builtins.head m;

      # Only the files the builds need, so unrelated edits (tests, docs, images) don't
      # invalidate the derivations.
      pythonSrc = lib.fileset.toSource {
        root = ./.;
        fileset = lib.fileset.unions [
          ./pyproject.toml
          ./MANIFEST.in
          ./README.md
          ./LICENSE
          ./COPYING
          ./unsloth
          ./unsloth_cli
          (lib.fileset.difference ./studio (
            lib.fileset.unions [
              ./studio/frontend
              ./studio/src-tauri
            ]
          ))
          # install.sh reads the app icons from here (see pyproject package-data).
          ./studio/src-tauri/icons
        ];
      };

      frontendSrc = lib.fileset.toSource {
        root = ./studio/frontend;
        fileset = lib.fileset.difference ./studio/frontend (
          lib.fileset.unions [
            (lib.fileset.maybeMissing ./studio/frontend/node_modules)
            (lib.fileset.maybeMissing ./studio/frontend/dist)
          ]
        );
      };

      # The Tauri crate plus install.sh, which tauri.linux.conf.json bundles as a resource
      # (`../../install.sh`); the frontend dist is copied in from studio-frontend.
      desktopSrc = lib.fileset.toSource {
        root = ./.;
        fileset = lib.fileset.unions [
          (lib.fileset.difference ./studio/src-tauri (lib.fileset.maybeMissing ./studio/src-tauri/target))
          ./install.sh
          # Frontend sources the crate include_str!s, so both sides share one definition.
          ./studio/frontend/src/features/browser/dangerous-file-types.json
          ./studio/frontend/src/features/auth/api.ts
          ./studio/frontend/src/features/settings/api/debug-logs.ts
          ./studio/frontend/src/lib/mac-stray-key-text.ts
        ];
      };

      # whisper.cpp tag pinned by scripts/build_whisper_cpp.sh (WHISPER_CPP_TAG).
      whisperCppTag = "v1.9.1";
    in
    {
      packages = forAllSystems (
        pkgs:
        let
          python = pkgs.python3;
          py = python.pkgs;

          # Step 1 of build.sh: the Vite frontend build (studio/frontend/dist).
          studio-frontend = pkgs.buildNpmPackage {
            pname = "unsloth-studio-frontend";
            inherit version;
            src = frontendSrc;
            nodejs = pkgs.nodejs_22;

            npmDepsHash = "sha256-W+yBYFeW5Tm+aMiF+hWjWwq7J15pv8nZ7tgzizpBTYg=";

            # .npmrc's min-release-age / allow-git need npm >= 11.10; the deps are already
            # pinned and hashed by the lockfile here, so the fetcher ignores them.
            npmFlags = [ "--ignore-scripts" ];
            makeCacheWritable = true;

            # build.sh's `npm run build`; force the pinned tsc rather than a Bun on PATH.
            env.UNSLOTH_TYPECHECK = "tsc";
            npmBuildScript = "build";

            installPhase = ''
              runHook preInstall

              # Same truncated-Tailwind guard as build.sh.
              max_css=$(find dist/assets -name '*.css' -exec wc -c {} + | sort -n | tail -1 | awk '{print $1}')
              if [ -z "$max_css" ] || [ "$max_css" -lt 100000 ]; then
                echo "ERROR: largest CSS file is ''${max_css:-missing} bytes (expected >100KB)" >&2
                exit 1
              fi

              cp -r dist $out
              runHook postInstall
            '';
          };

          # Steps 2-4 of build.sh: the unsloth wheel (CLI + Studio backend + bundled frontend).
          unsloth = py.buildPythonApplication {
            pname = "unsloth";
            inherit version;
            pyproject = true;
            src = pythonSrc;

            postPatch = ''
              # build-system pins exact setuptools versions; use the ones nixpkgs ships.
              substituteInPlace pyproject.toml \
                --replace-fail '"setuptools==84.1.0; python_version >= '"'"'3.10'"'"'",' '"setuptools",' \
                --replace-fail '"setuptools==82.0.1; python_version < '"'"'3.10'"'"'",' "" \
                --replace-fail '"setuptools-scm==9.2.2",' '"setuptools-scm",'

              mkdir -p studio/frontend
              cp -r ${studio-frontend} studio/frontend/dist
              chmod -R u+w studio/frontend/dist
            '';

            # No .git in the store: the dynamic version comes from unsloth/_version.py, and
            # setuptools-scm's file finder just falls back to package-data globs.
            env.SETUPTOOLS_SCM_PRETEND_VERSION = version;

            build-system = with py; [
              setuptools
              setuptools-scm
            ];

            dependencies = with py; [
              typer
              rich
              pydantic
              pyyaml
              json5
              nest-asyncio
              huggingface-hub
              structlog
              click
              certifi
            ];

            # Floors such as certifi>=2026.10.19 can run ahead of nixpkgs.
            pythonRelaxDeps = true;

            # The import check would pull in unsloth/__init__, which needs torch. The
            # torch/transformers stack is installed by `unsloth studio setup` at runtime.
            pythonImportsCheck = [ ];
            doCheck = false;

            passthru.frontend = studio-frontend;

            meta = {
              description = "2-5X faster training, reinforcement learning & finetuning";
              homepage = "https://github.com/unslothai/unsloth";
              license = with lib.licenses; [
                asl20
                agpl3Only
              ];
              mainProgram = "unsloth";
            };
          };

          # The Tauri desktop app (studio/src-tauri), as release-desktop.yml builds it but
          # unsigned. On first launch it runs the bundled install.sh, which installs the Python
          # stack under ~/.unsloth, exactly like the released .deb / AppImage.
          unsloth-desktop = pkgs.rustPlatform.buildRustPackage {
            pname = "unsloth-desktop";
            inherit version;
            src = desktopSrc;

            cargoRoot = "studio/src-tauri";
            buildAndTestSubdir = "studio/src-tauri";
            cargoHash = "sha256-LxEmOwuXJEQpUzixaD3z43ZoIiyinjnMn/s0Ksr9VGY=";

            postPatch = ''
              mkdir -p studio/frontend
              cp -r ${studio-frontend} studio/frontend/dist
              chmod -R u+w studio/frontend/dist
            '';

            # The frontend is prebuilt, and the updater artifacts need the release signing key.
            tauriBuildFlags = [
              "--config"
              (builtins.toJSON {
                build.beforeBuildCommand = "";
                bundle.createUpdaterArtifacts = false;
              })
            ];

            nativeBuildInputs = [
              pkgs.cargo-tauri.hook
              pkgs.pkg-config
            ]
            ++ lib.optionals pkgs.stdenv.hostPlatform.isLinux [ pkgs.wrapGAppsHook3 ];

            buildInputs = [
              pkgs.openssl
            ]
            ++ lib.optionals pkgs.stdenv.hostPlatform.isLinux (
              with pkgs;
              [
                webkitgtk_4_1
                gtk3
                glib-networking
                librsvg
                libsoup_3
                xdotool
                # The deb bundler looks it up via pkg-config; the tray dlopens it at runtime.
                libayatana-appindicator
                gst_all_1.gstreamer
                gst_all_1.gst-plugins-base
                gst_all_1.gst-plugins-good
                gst_all_1.gst-plugins-bad
                gst_all_1.gst-libav
              ]
            );

            # The tray icon dlopens libayatana-appindicator at runtime. The NPU backend
            # downloads prebuilt Ubuntu binaries into ~/.unsloth/studio/lemonade (lemond and
            # FastFlowLM's flm), which inherit this LD_LIBRARY_PATH through the Studio
            # backend. They also need an ELF interpreter at /lib64, i.e. programs.nix-ld.
            preFixup = lib.optionalString pkgs.stdenv.hostPlatform.isLinux ''
              gappsWrapperArgs+=(
                --prefix LD_LIBRARY_PATH : ${
                  lib.makeLibraryPath (
                    with pkgs;
                    [
                      libayatana-appindicator
                      # lemond
                      zlib
                      zstd
                      openssl
                      libdrm
                      # lemond, flm and its bundled XRT (libstdc++, libgomp)
                      stdenv.cc.cc.lib
                      # flm
                      curl
                      util-linux # libuuid
                    ]
                  )
                }
              )
            '';

            # The bundler fills Name= from productName ("Unsloth"); show a clearer label in
            # application menus without renaming the product (window title, bundle paths).
            postInstall = lib.optionalString pkgs.stdenv.hostPlatform.isLinux ''
              for f in $out/share/applications/*.desktop; do
                substituteInPlace "$f" --replace-fail 'Name=Unsloth' 'Name=Unsloth Desktop'
              done
            '';

            # The crate's tests touch $HOME, spawn shells and need a display.
            doCheck = false;

            meta = {
              description = "Unsloth Studio desktop app";
              homepage = "https://unsloth.ai/";
              license = lib.licenses.agpl3Only;
              mainProgram = "unsloth-studio";
              platforms = lib.platforms.linux ++ lib.platforms.darwin;
            };
          };

          # scripts/build_whisper_cpp.sh: whisper.cpp's whisper-server, static ggml.
          mkWhisperServer =
            {
              pkgs,
              cudaSupport ? false,
            }:
            pkgs.stdenv.mkDerivation {
              pname = "whisper-server" + lib.optionalString cudaSupport "-cuda";
              version = lib.removePrefix "v" whisperCppTag;

              src = pkgs.fetchFromGitHub {
                owner = "ggml-org";
                repo = "whisper.cpp";
                rev = whisperCppTag;
                hash = "sha256-tQtmTZTCw8f5u54MKSjlPzPRUwEeXvyDSsPjgSqu9dY=";
              };

              nativeBuildInputs = [
                pkgs.cmake
              ]
              ++ lib.optionals cudaSupport [ pkgs.cudaPackages.cuda_nvcc ];

              buildInputs = lib.optionals cudaSupport (
                with pkgs.cudaPackages;
                [
                  cuda_cudart
                  libcublas
                  cccl
                ]
              );

              cmakeFlags = [
                (lib.cmakeBool "BUILD_SHARED_LIBS" false)
                (lib.cmakeBool "GGML_CUDA" cudaSupport)
                # Build for a generic CPU rather than the build host's.
                (lib.cmakeBool "GGML_NATIVE" false)
              ];

              buildPhase = ''
                runHook preBuild
                cmake --build . --config Release --target whisper-server -j$NIX_BUILD_CORES
                runHook postBuild
              '';

              installPhase = ''
                runHook preInstall
                install -Dm755 bin/whisper-server $out/bin/whisper-server
                runHook postInstall
              '';

              doInstallCheck = true;
              installCheckPhase = ''
                $out/bin/whisper-server --help >/dev/null
              '';

              meta = {
                description = "whisper.cpp HTTP server used by Unsloth Studio speech-to-text";
                homepage = "https://github.com/ggml-org/whisper.cpp";
                license = lib.licenses.mit;
                mainProgram = "whisper-server";
              };
            };
        in
        {
          inherit studio-frontend unsloth unsloth-desktop;
          whisper-server = mkWhisperServer { inherit pkgs; };
          default = unsloth;
        }
        // lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
          # GGML_CUDA=1 scripts/build_whisper_cpp.sh. CUDA is unfree, so this uses its own nixpkgs.
          whisper-server-cuda = mkWhisperServer {
            pkgs = import nixpkgs {
              system = pkgs.stdenv.hostPlatform.system;
              config = {
                allowUnfree = true;
                cudaSupport = true;
              };
            };
            cudaSupport = true;
          };
        }
      );

      apps = forAllSystems (
        pkgs:
        let
          pkgsFor = self.packages.${pkgs.stdenv.hostPlatform.system};
        in
        rec {
          unsloth = {
            type = "app";
            program = lib.getExe pkgsFor.unsloth;
            meta.description = "Unsloth CLI (training, inference, export, Studio)";
          };
          unsloth-desktop = {
            type = "app";
            program = lib.getExe pkgsFor.unsloth-desktop;
            meta.description = "Unsloth Studio desktop app";
          };
          default = unsloth;
        }
      );

      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          inputsFrom = [ self.packages.${pkgs.stdenv.hostPlatform.system}.unsloth ];
          packages = with pkgs; [
            nodejs_22
            python3Packages.build
            cmake
            git
          ];
        };
      });

      formatter = forAllSystems (pkgs: pkgs.nixfmt);
    };
}
