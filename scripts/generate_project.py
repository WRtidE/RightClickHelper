#!/usr/bin/env python3
"""Generate a small, deterministic Xcode project without third-party tools."""
from pathlib import Path
import hashlib
import json
import plistlib

ROOT = Path(__file__).resolve().parents[1]
objects = {}


def ident(name):
    return hashlib.sha256(name.encode()).hexdigest()[:24].upper()


def obj(object_key, isa, **values):
    key = ident(object_key)
    objects[key] = dict(isa=isa, **values)
    return key


def serialize(value, level=0):
    pad = "\t" * level
    if isinstance(value, dict):
        return "{\n" + "".join(f'{pad}\t{k} = {serialize(v, level + 1)};\n' for k, v in value.items()) + pad + "}"
    if isinstance(value, list):
        return "(\n" + "".join(f'{pad}\t{serialize(v, level + 1)},\n' for v in value) + pad + ")"
    return json.dumps(str(value), ensure_ascii=False)


base = obj("base-config", "PBXFileReference", lastKnownFileType="text.xcconfig", path="Config/Project.xcconfig", sourceTree="<group>")
app_product = obj("app-product", "PBXFileReference", explicitFileType="wrapper.application", path="RightClickHelper.app", sourceTree="BUILT_PRODUCTS_DIR")
ext_product = obj("ext-product", "PBXFileReference", explicitFileType="wrapper.app-extension", path="FinderExtension.appex", sourceTree="BUILT_PRODUCTS_DIR")
products = obj("products", "PBXGroup", name="Products", children=[app_product, ext_product], sourceTree="<group>")
source_refs = {}
groups = []
for folder in ("App", "FinderExtension", "Shared"):
    refs = []
    for path in sorted((ROOT / folder).glob("*.swift")):
        relative = str(path.relative_to(ROOT))
        ref = obj(relative, "PBXFileReference", lastKnownFileType="sourcecode.swift", path=relative, sourceTree="SOURCE_ROOT")
        source_refs[relative] = ref
        refs.append(ref)
    groups.append(obj(folder + "-group", "PBXGroup", name=folder, children=refs, sourceTree="<group>"))
resource_refs = []
for extension in ("docx", "pptx", "xlsx"):
    relative = f"Shared/Resources/blank.{extension}"
    resource_refs.append(obj(relative, "PBXFileReference", lastKnownFileType="file", path=relative, sourceTree="SOURCE_ROOT"))
resource_refs.append(obj("ThirdPartyNotices.txt", "PBXFileReference", lastKnownFileType="text", path="ThirdPartyNotices.txt", sourceTree="SOURCE_ROOT"))
resource_refs.append(obj("App/Resources/AppIcon.icns", "PBXFileReference", lastKnownFileType="image.icns", path="App/Resources/AppIcon.icns", sourceTree="SOURCE_ROOT"))
resources = obj("resources-group", "PBXGroup", name="Resources", children=resource_refs, sourceTree="<group>")
main_group = obj("main-group", "PBXGroup", children=groups + [resources, base, products], sourceTree="<group>")


def configs(name, settings):
    refs = []
    for variant in ("Debug", "Release"):
        values = dict(settings)
        values["SWIFT_OPTIMIZATION_LEVEL"] = "-Onone" if variant == "Debug" else "-O"
        values["DEBUG_INFORMATION_FORMAT"] = "dwarf" if variant == "Debug" else "dwarf-with-dsym"
        refs.append(obj(name + variant, "XCBuildConfiguration", baseConfigurationReference=base,
                        buildSettings=values, name=variant))
    return obj(name + "configs", "XCConfigurationList", buildConfigurations=refs, defaultConfigurationIsVisible=0, defaultConfigurationName="Debug")


def source_phase(target, folders):
    builds = []
    for path, ref in source_refs.items():
        if path.split("/")[0] in folders:
            builds.append(obj(target + path, "PBXBuildFile", fileRef=ref))
    return obj(target + "sources", "PBXSourcesBuildPhase", buildActionMask=2147483647, files=builds, runOnlyForDeploymentPostprocessing=0)


resource_phase = obj("app-resources", "PBXResourcesBuildPhase", buildActionMask=2147483647,
                     files=[obj("app-resource-" + ref, "PBXBuildFile", fileRef=ref) for ref in resource_refs],
                     runOnlyForDeploymentPostprocessing=0)

common = {"SDKROOT": "macosx", "MACOSX_DEPLOYMENT_TARGET": "14.0", "SWIFT_VERSION": "5.0",
          "CLANG_ENABLE_MODULES": "YES", "CODE_SIGN_STYLE": "Manual", "CODE_SIGN_IDENTITY": "Apple Development",
          "ENABLE_HARDENED_RUNTIME": "YES", "CODE_SIGN_INJECT_BASE_ENTITLEMENTS": "NO",
          "GENERATE_INFOPLIST_FILE": "NO", "CURRENT_PROJECT_VERSION": "24", "MARKETING_VERSION": "0.7.2"}
ext_settings = dict(common, PRODUCT_NAME="FinderExtension", PRODUCT_BUNDLE_IDENTIFIER="dev.rightclickhelper.prototype.FinderExtension",
                    INFOPLIST_FILE="Config/Extension-Info.plist", CODE_SIGN_ENTITLEMENTS="Config/Extension.entitlements",
                    APPLICATION_EXTENSION_API_ONLY="YES", SKIP_INSTALL="YES", LD_RUNPATH_SEARCH_PATHS="$(inherited) @executable_path/../Frameworks @executable_path/../../../../Frameworks")
ext_target = obj("extension-target", "PBXNativeTarget", buildConfigurationList=configs("extension", ext_settings),
                 buildPhases=[source_phase("extension", ["FinderExtension", "Shared"])], buildRules=[], dependencies=[],
                 name="FinderExtension", productName="FinderExtension", productReference=ext_product, productType="com.apple.product-type.app-extension")
proxy = obj("extension-proxy", "PBXContainerItemProxy", containerPortal=ident("project"), proxyType=1,
            remoteGlobalIDString=ext_target, remoteInfo="FinderExtension")
dependency = obj("extension-dependency", "PBXTargetDependency", target=ext_target, targetProxy=proxy)
embed_file = obj("embed-file", "PBXBuildFile", fileRef=ext_product, settings={"ATTRIBUTES": ["RemoveHeadersOnCopy"]})
embed_phase = obj("embed-phase", "PBXCopyFilesBuildPhase", buildActionMask=2147483647, dstPath="", dstSubfolderSpec=13,
                  files=[embed_file], name="Embed App Extensions", runOnlyForDeploymentPostprocessing=0)
app_settings = dict(common, PRODUCT_NAME="RightClickHelper", PRODUCT_BUNDLE_IDENTIFIER="dev.rightclickhelper.prototype",
                    INFOPLIST_FILE="Config/App-Info.plist", CODE_SIGN_ENTITLEMENTS="Config/App.entitlements",
                    LD_RUNPATH_SEARCH_PATHS="$(inherited) @executable_path/../Frameworks", COMBINE_HIDPI_IMAGES="YES")
app_target = obj("app-target", "PBXNativeTarget", buildConfigurationList=configs("app", app_settings),
                 buildPhases=[source_phase("app", ["App", "Shared"]), resource_phase, embed_phase], buildRules=[], dependencies=[dependency],
                 name="RightClickHelper", productName="RightClickHelper", productReference=app_product, productType="com.apple.product-type.application")
project = obj("project", "PBXProject", attributes={"LastUpgradeCheck": "2630", "BuildIndependentTargetsInParallel": "YES"},
              buildConfigurationList=configs("project", {}), compatibilityVersion="Xcode 14.0", developmentRegion="zh-Hans",
              knownRegions=["zh-Hans", "en", "Base"], mainGroup=main_group, productRefGroup=products,
              projectDirPath="", projectRoot="", targets=[app_target, ext_target])
directory = ROOT / "RightClickHelper.xcodeproj"
directory.mkdir(exist_ok=True)
(directory / "project.pbxproj").write_text("// !$*UTF8*$!\n" + serialize(dict(archiveVersion=1, classes={}, objectVersion=56, objects=objects, rootObject=project)) + "\n")
scheme_dir = directory / "xcshareddata/xcschemes"
scheme_dir.mkdir(parents=True, exist_ok=True)
(scheme_dir / "RightClickHelper.xcscheme").write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2630" version="1.3">
 <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{app_target}" BuildableName="RightClickHelper.app" BlueprintName="RightClickHelper" ReferencedContainer="container:RightClickHelper.xcodeproj"/></BuildActionEntry></BuildActionEntries></BuildAction>
 <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{app_target}" BuildableName="RightClickHelper.app" BlueprintName="RightClickHelper" ReferencedContainer="container:RightClickHelper.xcodeproj"/></BuildableProductRunnable></LaunchAction>
 <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
''')

info = dict(CFBundleDevelopmentRegion="zh_CN", CFBundleExecutable="$(EXECUTABLE_NAME)",
            CFBundleIdentifier="$(PRODUCT_BUNDLE_IDENTIFIER)", CFBundleInfoDictionaryVersion="6.0",
            CFBundleName="$(PRODUCT_NAME)", CFBundleShortVersionString="$(MARKETING_VERSION)",
            CFBundleVersion="$(CURRENT_PROJECT_VERSION)", LSMinimumSystemVersion="$(MACOSX_DEPLOYMENT_TARGET)",
            SharedGroupIdentifier="$(DEVELOPMENT_TEAM).dev.rightclickhelper.prototype")
app_info = dict(info, CFBundlePackageType="APPL", CFBundleDisplayName="右键助手", NSPrincipalClass="NSApplication",
                CFBundleIconFile="AppIcon", LSUIElement=True, NSHighResolutionCapable=True, CFBundleURLTypes=[dict(CFBundleURLName="dev.rightclickhelper.prototype.request",
                CFBundleURLSchemes=["rightclickhelper-prototype"], CFBundleTypeRole="Editor")])
# The four services receive selected filesystem objects, never arbitrary text.
app_info["NSServices"] = [
    dict(NSMenuItem={"default": title}, NSMessage="handleFiles", NSPortName="RightClickHelper",
         NSUserData=action,
         NSSendFileTypes=["public.folder" if action == "create" else "public.item"],
         NSRequiredContext={}, NSRestricted=False, NSTimeout="10000",
         NSServiceDescription="使用右键助手处理选中的文件或文件夹")
    for action, title in [("copyPath", "右键助手：复制完整路径"), ("create", "右键助手：新建文件…"),
                          ("terminal", "右键助手：在此打开终端"), ("applications", "右键助手：用常用应用打开…")]]
# NSSendTypes and NSSendFileTypes are alternative matches. Keeping generic URL
# types on the folder-only service would also expose it for regular files.
for service in app_info["NSServices"]:
    if service["NSUserData"] != "create":
        service["NSSendTypes"] = ["public.file-url", "NSFilenamesPboardType"]
ext_info = dict(info, CFBundlePackageType="XPC!", CFBundleDisplayName="右键助手 Finder", NSExtension=dict(
    NSExtensionPointIdentifier="com.apple.FinderSync", NSExtensionPrincipalClass="$(PRODUCT_MODULE_NAME).FinderSync",
    NSExtensionAttributes={}))
entitlements = {"com.apple.security.app-sandbox": True,
                "com.apple.security.application-groups": ["$(DEVELOPMENT_TEAM).dev.rightclickhelper.prototype"]}
app_entitlements = dict(entitlements, **{"com.apple.security.files.user-selected.read-write": True,
                                        "com.apple.security.files.bookmarks.app-scope": True})
ext_entitlements = dict(entitlements, **{"com.apple.security.files.user-selected.read-only": True})
for name, value in [("App-Info.plist", app_info), ("Extension-Info.plist", ext_info),
                    ("App.entitlements", app_entitlements), ("Extension.entitlements", ext_entitlements)]:
    (ROOT / "Config" / name).write_bytes(plistlib.dumps(value))
print("Generated RightClickHelper.xcodeproj and target configuration.")
