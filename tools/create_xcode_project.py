#!/usr/bin/env python3
"""Generate the small, dependency-free visionOS Xcode project."""
from pathlib import Path
import hashlib
import os

ROOT = Path(__file__).resolve().parents[1] / "visionOS"
PROJECT = ROOT / "Euphoria.xcodeproj"
PROJECT.mkdir(exist_ok=True)
objects = []


def uid(name):
    return hashlib.sha256(name.encode()).hexdigest()[:24].upper()


def add(name, body):
    objects.append(f"\t\t{uid(name)} = {{ {body} }};")
    return uid(name)


sources, refs = [], []
for file in sorted(list((ROOT / "Euphoria").glob("*.swift")) + list((ROOT / "Euphoria").glob("*.metal"))):
    kind = "sourcecode.metal" if file.suffix == ".metal" else "sourcecode.swift"
    ref = add(file.name, f'isa = PBXFileReference; lastKnownFileType = {kind}; path = "{file.name}"; sourceTree = "<group>";')
    refs.append(ref)
    sources.append(add("build" + file.name, f"isa = PBXBuildFile; fileRef = {ref};"))
# The app icon's asset catalog is made locally (tools/make_icon.swift) and kept out of git.
has_icon = (ROOT / "Euphoria" / "Assets.xcassets").exists()
assets = add("assets", 'isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; path = "Assets.xcassets"; sourceTree = "<group>";') if has_icon else None
game = add("game", 'isa = PBXFileReference; lastKnownFileType = folder; path = Resources/Game; sourceTree = "<group>";')
fonts = add("fonts", 'isa = PBXFileReference; lastKnownFileType = folder; path = Resources/Fonts; sourceTree = "<group>";')
resources = ",".join([add("gameBuild", f"isa = PBXBuildFile; fileRef = {game};"),
                      add("fontsBuild", f"isa = PBXBuildFile; fileRef = {fonts};")]
                     + ([add("assetsBuild", f"isa = PBXBuildFile; fileRef = {assets};")] if has_icon else []))
info = add("info", 'isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = Info.plist; sourceTree = "<group>";')
product = add("product", 'isa = PBXFileReference; explicitFileType = wrapper.application; path = Euphoria.app; sourceTree = BUILT_PRODUCTS_DIR;')
group = add("appGroup", f'isa = PBXGroup; children = ({",".join(refs + [game, fonts, info] + ([assets] if has_icon else []))},); path = Euphoria; sourceTree = "<group>";')
products = add("products", f'isa = PBXGroup; children = ({product},); name = Products; sourceTree = "<group>";')
main = add("main", f'isa = PBXGroup; children = ({group}, {products},); sourceTree = "<group>";')
source_phase = add("sources", f'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ({",".join(sources)},); runOnlyForDeploymentPostprocessing = 0;')
resource_phase = add("resources", f'isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = ({resources},); runOnlyForDeploymentPostprocessing = 0;')
framework_phase = add("frameworks", 'isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;')
for level in ["project", "target"]:
    configs = []
    for mode in ["Debug", "Release"]:
        settings = '''CLANG_ENABLE_MODULES = YES; SDKROOT = xros; XROS_DEPLOYMENT_TARGET = 26.0; SWIFT_VERSION = 5.0;'''
        if level == "target":
            settings += ''' PRODUCT_NAME = Euphoria; PRODUCT_BUNDLE_IDENTIFIER = com.euphoria.vision;
            INFOPLIST_FILE = Euphoria/Info.plist; TARGETED_DEVICE_FAMILY = 7;
            SUPPORTED_PLATFORMS = "xros xrsimulator"; CODE_SIGN_STYLE = Automatic;
            GENERATE_INFOPLIST_FILE = NO;
            LD_RUNPATH_SEARCH_PATHS = "$(inherited) @executable_path/Frameworks";'''
            if has_icon:
                settings += " ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;"
            if os.environ.get("DEVELOPMENT_TEAM"):
                settings += f' DEVELOPMENT_TEAM = {os.environ["DEVELOPMENT_TEAM"]};'
            if os.environ.get("BUNDLE_ID"):
                settings = settings.replace("com.euphoria.vision", os.environ["BUNDLE_ID"])
        settings += ' SWIFT_OPTIMIZATION_LEVEL = "-Onone"; DEBUG_INFORMATION_FORMAT = dwarf; SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG;' if mode == "Debug" else ' SWIFT_OPTIMIZATION_LEVEL = "-O"; DEBUG_INFORMATION_FORMAT = "dwarf-with-dsym";'
        configs.append(add(level + mode, f'isa = XCBuildConfiguration; buildSettings = {{ {settings} }}; name = {mode};'))
    add(level + "Configs", f'isa = XCConfigurationList; buildConfigurations = ({",".join(configs)},); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
target = add("target", f'isa = PBXNativeTarget; buildConfigurationList = {uid("targetConfigs")}; buildPhases = ({source_phase},{framework_phase},{resource_phase},); buildRules = (); dependencies = (); name = Euphoria; productName = Euphoria; productReference = {product}; productType = "com.apple.product-type.application";')
project = add("project", f'isa = PBXProject; attributes = {{ LastUpgradeCheck = 2700; }}; buildConfigurationList = {uid("projectConfigs")}; compatibilityVersion = "Xcode 14.0"; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en, Base,); mainGroup = {main}; productRefGroup = {products}; projectDirPath = ""; projectRoot = ""; targets = ({target},);')
(PROJECT / "project.pbxproj").write_text('// !$*UTF8*$!\n{ archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n' + '\n'.join(objects) + f'\n}}; rootObject = {project}; }}\n')
schemes = PROJECT / "xcshareddata" / "xcschemes"
schemes.mkdir(parents=True, exist_ok=True)
reference = f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="Euphoria.app" BlueprintName="Euphoria" ReferencedContainer="container:Euphoria.xcodeproj"/>'
(schemes / "Euphoria.xcscheme").write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2700" version="1.3">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{reference}</BuildActionEntry></BuildActionEntries></BuildAction>
<LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{reference}</BuildableProductRunnable></LaunchAction>
<ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{reference}</BuildableProductRunnable></ProfileAction>
<AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>''')
print(PROJECT)
