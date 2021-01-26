{ src, version, llvmVersions, gccConstraints, system, debug ? false, }:
final: prev:
with final;
let
  dbg = if debug == true then enableDebugging else (x: x);

  nativeBuildInputs = [ cmake ninja python27 ];

  buildInputs = [ ncurses readline zlib python27 ];

  doCheck = true;

  doTarget = "test";

  dontStrip = debug;

  separateDebugInfo = debug;

  meta = with stdenv.lib; {
    description = "A language and an embedded JIT compiler";
    longDescription = ''
      Hobbes is a language, embedded compiler, and runtime for efficient
      dynamic expression evalution, data storage and analysis.
    '';
    license = licenses.asl20;
    maintainers = with maintainers; [ kthielen thmzlt smunix ];
  };

  when = c: m: if c then m else { };

  withGCC = { gccVersion ? 10 }:
    let
      gccPkgs = { gccVersion }:
        builtins.getAttr ("gcc" + (toString gccVersion) + "Stdenv") final;
      llvmPkgs = { llvmVersion }:
        builtins.getAttr ("llvmPackages_" + (toString llvmVersion)) final;
    in makeOverridable
    ({ llvmVersion, stdenv ? (gccPkgs { inherit gccVersion; }) }:
      stdenv.mkDerivation {
        pname = "hobbes-gcc-" + toString gccVersion + "-llvm-"
          + toString llvmVersion;
        inherit version src meta doCheck doTarget dontStrip;
        nativeBuildInputs = nativeBuildInputs;
        buildInputs = buildInputs
                      ++ [ (llvmPkgs { inherit llvmVersion; }).llvm ];
        postPatch = ''
          substituteInPlace CMakeLists.txt \
             --replace "\''${CMAKE_SOURCE_DIR}" "${src}"
        '';
      });

  withCLANG = let
    llvmPkgs = { llvmVersion }: final."llvmPackages_${toString llvmVersion}";
  in makeOverridable
  ({ llvmVersion, stdenv ? (llvmPkgs { inherit llvmVersion; }).stdenv }:
    stdenv.mkDerivation {
      pname = "hobbes-clang-" + toString llvmVersion;
      inherit version src meta doCheck doTarget dontStrip;
      nativeBuildInputs = nativeBuildInputs;
      buildInputs = buildInputs
                    ++ [ (llvmPkgs { inherit llvmVersion; }).llvm ];
      postPatch = ''
        substituteInPlace CMakeLists.txt \
           --replace "\''${CMAKE_SOURCE_DIR}" "${src}"
      '';
    });
  
  withSHAKE = let
    llvmPkgs = { llvmVersion }: final."llvmPackages_${toString llvmVersion}";
    gccPkgs = { gccVersion ? 10 }: final."gcc${toString gccVersion}Stdenv";
  in makeOverridable
    ({ llvmVersion
     , gccVersion
     , platform 
     , ncurses ? final.ncurses
     , zlib ? final.zlib
     , readline ? final.readline
     , xcbuild ? final.xcbuild
     , libcxxStdenv ? final.libcxxStdenv
     , cabal-install ? final.cabal-install
     , binutils ? final.binutils
     , stdenv ? (llvmPkgs { inherit llvmVersion; }).stdenv
     }:
       stdenv.mkDerivation rec {
         pname = "hobbes-shake-" + toString llvmVersion;
         inherit version src meta;
         shakeBuild = (with haskellPackages; with (llvmPkgs { inherit llvmVersion; });
           haskell.lib.overrideCabal (callCabal2nix "shakeBuild" "${src}/shake" {
             inherit
               shake
             ;
             shake-language-c = callPackage (fetchGit {
               url = "https://github.com/smunix/shake-language-c";
               rev = "f0b258b9c3cfa56b569cdaf3a61b787c46be3cd6";
               allRefs = true;
             }) {};
           }) (old: {
             postPatch = ''
             substituteInPlace Shakefile.hs \
               --replace "\''${zlib-dev}" "${zlib}/include" \
               --replace "\''${ncurses-dev}" "${ncurses}/include" \
               --replace "\''${libcxx-dev}" "${llvmPackages.libcxx}/include/c++/v1" \
               --replace "\''${llvm-dev}" "${llvm}/include" \
               --replace "\''${llvm-lib}" "${llvm}/lib" \
               --replace "\''${readline-lib}" "${readline}/lib" \
               --replace "\''${readline-dev}" "${readline.dev}/include" \
               --replace "\''${toolChain}" "${if stdenv.isDarwin then "toolChainOSX" else "toolChainLinux"}" \
               --replace "\''${target}" "${if stdenv.isDarwin then "targetOSX" else "targetLinux"}"
             '';
           }));
         nativeBuildInputs = [
           final."clang_${toString llvmVersion}"
           binutils
           pkgconfig
           shakeBuild
           cabal-install
         ] ++ (if platform.isDarwin then [ xcbuild ] else []);
         propagatedBuildInputs = with (llvmPkgs { inherit llvmVersion; }); [
           zlib ncurses readline llvm
           libcxx
           (stdenv.lib.getDev stdenv.cc.libc)
           libcxxStdenv
         ];
         buildPhase = ''
           ${shakeBuild}/bin/shakeBuild +RTS -N
         '';
         installPhase = if platform.isDarwin
                        then ''
                               mkdir -p "$out"/{bin,test}
                               install build/macosx/x86_64/hi-A build/macosx/x86_64/hog-A "$out"/bin
                               install build/macosx/x86_64/hobbes-test-A "$out"/test
                             ''
                        else ''
                               mkdir -p "$out"/{bin,test}
                               install build/linux/x86_64/hi-A build/linux/x86_64/hog-A "$out"/bin
                               install build/linux/x86_64/hobbes-test-A "$out"/test
                        '';
       });
  
in rec {
  hobbesPackages = when stdenv.isLinux (recurseIntoAttrs (builtins.listToAttrs
    (builtins.map (gccConstraint: {
      name = "gcc-" + toString gccConstraint.gccVersion;
      value = recurseIntoAttrs (builtins.listToAttrs (builtins.map
        (llvmVersion: {
          name = "llvm-" + toString llvmVersion;
          value = recurseIntoAttrs ({
            hobbes = dbg
              (callPackage (withGCC { inherit (gccConstraint) gccVersion; }) {
                inherit llvmVersion;
              });
          });
        }) gccConstraint.llvmVersions));
    }) gccConstraints))) // recurseIntoAttrs (builtins.listToAttrs (builtins.map
      (llvmVersion: {
        name = "clang-" + toString llvmVersion;
        value = recurseIntoAttrs ({
          hobbes = dbg (callPackage withCLANG { inherit llvmVersion; });
        });
      }) llvmVersions)) // recurseIntoAttrs (builtins.listToAttrs (builtins.map
        (llvmVersion: {
          name = "shake-" + toString llvmVersion;
          value = recurseIntoAttrs ({
            hobbes = dbg (callPackage withSHAKE {
              inherit llvmVersion;
              gccVersion = 10;
              platform = {
                isDarwin = stdenv.isDarwin;
                isLinux = stdenv.isLinux;
              };
            });
          });
        }) llvmVersions))
        ;
}
