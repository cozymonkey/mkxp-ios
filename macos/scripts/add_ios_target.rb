#!/usr/bin/env ruby
# frozen_string_literal: true
#
# add_ios_target.rb — adds (or regenerates) the "Z-iOS" application target to
# mkxp-z.xcodeproj. iOS arm64 device build of mkxp-z for the Another Red port.
#
# Prerequisite:  gem install --user-install xcodeproj   (tested with 1.27.0)
# Usage:         cd macos && ruby scripts/add_ios_target.rb
#
# Idempotent: re-running removes the existing Z-iOS target and the groups this
# script creates, then rebuilds them. Commit BOTH this script and the resulting
# project.pbxproj (xcodeproj re-serializes the whole file; the meaningful change
# is the Z-iOS target).
#
# Design notes (verified against the codebase):
#  - iOS uses the native OpenGLES.framework + SDL2's EAGL backend; ANGLE
#    (libEGL/libGLESv2) is NOT linked or embedded.
#  - libfluidsynth.dylib statically embeds glib, so the app does NOT link the
#    glib stack (mirrors the macOS target, which also omits it).
#  - jxl/brotli/hwy are absent from the iOS deps (SDL2_image built with no JXL).
#  - The shared src set is reused as-is, minus the macOS-only UI
#    (TouchBar.mm, SettingsMenuController.mm), plus the two iOS bridges.

require 'xcodeproj'

PROJECT     = 'mkxp-z.xcodeproj'
TARGET_NAME = 'Z-iOS'
TEMPLATE    = 'Z-universal'
DEP_LIB     = 'Dependencies/build-iphoneos-arm64/lib'  # relative to PROJECT_DIR (macos/)

# Static libs the engine links (macOS list minus jxl/brotli/hwy; no glib).
STATIC_LIBS = %w[
  libSDL2.a libSDL2main.a libSDL2_image.a libSDL2_ttf.a libSDL2_sound.a
  libopenal.a libvorbis.a libvorbisfile.a libvorbisenc.a libogg.a libtheora.a
  libpng16.a libpixman-1.a libfreetype.a libssl.a libcrypto.a libphysfs.a
  libuchardet.a
].freeze

# Dylibs: linked AND embedded (code-signed on copy). libruby provides link-time
# symbols (ruby_init etc.); libfluidsynth is also dlopen'd at runtime via @rpath.
DYLIBS = %w[libruby.3.1.dylib libfluidsynth.dylib].freeze

# iOS system frameworks (from sdl2.pc + fluidsynth). Weak where SDL weak-links.
FRAMEWORKS = %w[
  UIKit OpenGLES Metal QuartzCore CoreGraphics CoreMotion AVFoundation
  CoreBluetooth CoreVideo CoreAudio AudioToolbox Foundation CoreFoundation
].freeze
WEAK_FRAMEWORKS = %w[GameController CoreHaptics].freeze
TBD_LIBS = %w[z iconv bz2].freeze

proj = Xcodeproj::Project.open(PROJECT)

# ---------------------------------------------------------------------------
# Idempotency: tear down a previous run.
# ---------------------------------------------------------------------------
if (old = proj.targets.find { |t| t.name == TARGET_NAME })
  puts "Removing existing #{TARGET_NAME} target"
  old.build_configuration_list.build_configurations.each(&:remove_from_project)
  old.build_configuration_list.remove_from_project
  old.build_phases.each(&:remove_from_project)
  # drop any dependency objects pointing at it
  proj.targets.each do |t|
    t.dependencies.dup.each do |d|
      d.remove_from_project if d.target == old
    end
  end
  old.remove_from_project
end
%w[iOS\ Libraries iOS\ Frameworks iOS\ Resources].each do |gname|
  g = proj.main_group.children.find { |c| c.is_a?(Xcodeproj::Project::Object::PBXGroup) && c.display_name == gname }
  g&.remove_from_project
end

template = proj.targets.find { |t| t.name == TEMPLATE }
raise "template target #{TEMPLATE} not found" unless template

# ---------------------------------------------------------------------------
# New application target.
# ---------------------------------------------------------------------------
ios = proj.new_target(:application, TARGET_NAME, :ios, '14.0', proj.products_group)

# Base xcconfig (resolves DEPENDENCY_SEARCH_PATH -> build-iphoneos-arm64).
xcconfig_ref = proj.main_group.files.find { |f| f.path == 'config/mkxp.iOS.xcconfig' } ||
               proj.main_group.new_file('config/mkxp.iOS.xcconfig')

# HEADER_SEARCH_PATHS: template's, minus the ANGLE entry (iOS has no ANGLE).
tmpl_hdr = template.build_configurations.first.build_settings['HEADER_SEARCH_PATHS'] || []
ios_hdr  = tmpl_hdr.reject { |p| p.include?('ANGLE') }

ios.build_configurations.each do |cfg|
  cfg.base_configuration_reference = xcconfig_ref
  bs = cfg.build_settings

  # Inherit the project-level GCC_PREPROCESSOR_DEFINITIONS (MKXPZ_BUILD_XCODE,
  # GLES2_HEADER, MKXPZ_MINIFFI, ...) — delete any target-level shadow.
  bs.delete('GCC_PREPROCESSOR_DEFINITIONS')
  # Avoid auto-generated Info.plist clashing with our INFOPLIST_FILE.
  bs.delete('GENERATE_INFOPLIST_FILE')
  bs.keys.grep(/^INFOPLIST_KEY_/).each { |k| bs.delete(k) }

  bs['SDKROOT']                       = 'iphoneos'
  bs['SUPPORTED_PLATFORMS']           = 'iphoneos'
  bs['TARGETED_DEVICE_FAMILY']        = '1,2'
  bs['IPHONEOS_DEPLOYMENT_TARGET']    = '14.0'
  bs['ARCHS']                         = 'arm64'
  bs['ONLY_ACTIVE_ARCH']              = 'YES' if cfg.name == 'Debug'
  bs['INFOPLIST_FILE']                = 'Info-iOS.plist'
  bs['PRODUCT_BUNDLE_IDENTIFIER']     = 'org.mkxpz.anotherred' # change + set DEVELOPMENT_TEAM in Xcode
  bs['PRODUCT_NAME']                  = '$(TARGET_NAME)'
  bs['CODE_SIGN_ENTITLEMENTS']        = 'mkxp.iOS.entitlements'
  bs['CODE_SIGN_STYLE']               = 'Automatic'
  bs['CLANG_ENABLE_OBJC_ARC']         = 'YES'
  bs['CLANG_CXX_LANGUAGE_STANDARD']   = 'c++14'
  bs['OTHER_CFLAGS']                  = '-fdeclspec'
  bs['ENABLE_BITCODE']                = 'NO'
  bs['LD_RUNPATH_SEARCH_PATHS']       = ['$(inherited)', '@executable_path/Frameworks']
  bs['LIBRARY_SEARCH_PATHS']          = ['$(inherited)', '$(DEPENDENCY_SEARCH_PATH)/lib']
  bs['HEADER_SEARCH_PATHS']           = ios_hdr
  bs.delete('MACOSX_DEPLOYMENT_TARGET')
end

# ---------------------------------------------------------------------------
# Sources: reuse template's file refs, minus macOS-only UI, plus iOS bridges.
# ---------------------------------------------------------------------------
EXCLUDE_SRC = ['TouchBar.mm', 'SettingsMenuController.mm'].freeze
template.source_build_phase.files.each do |bf|
  next unless bf.file_ref
  next if EXCLUDE_SRC.include?(bf.file_ref.display_name)
  ios.source_build_phase.add_file_reference(bf.file_ref)
end
ios_src = proj.main_group.new_file('../src/audio/audiosession-ios.mm')
ios.source_build_phase.add_file_reference(ios_src)
touch_src = proj.main_group.new_file('views/TouchControls.mm')
ios.source_build_phase.add_file_reference(touch_src)

# ---------------------------------------------------------------------------
# Frameworks phase: static libs + dylibs + system frameworks + tbd.
# ---------------------------------------------------------------------------
libs_group = proj.main_group.new_group('iOS Libraries')
STATIC_LIBS.each do |name|
  ref = libs_group.new_file("#{DEP_LIB}/#{name}")
  ios.frameworks_build_phase.add_file_reference(ref)
end
dylib_refs = {}
DYLIBS.each do |name|
  ref = libs_group.new_file("#{DEP_LIB}/#{name}")
  dylib_refs[name] = ref
  ios.frameworks_build_phase.add_file_reference(ref)
end

fw_group = proj.main_group.new_group('iOS Frameworks')
add_fw = lambda do |name, weak|
  ref = fw_group.new_file("System/Library/Frameworks/#{name}.framework")
  ref.source_tree = 'SDKROOT'
  bf = ios.frameworks_build_phase.add_file_reference(ref)
  bf.settings = { 'ATTRIBUTES' => ['Weak'] } if weak
end
FRAMEWORKS.each { |f| add_fw.call(f, false) }
WEAK_FRAMEWORKS.each { |f| add_fw.call(f, true) }
TBD_LIBS.each do |name|
  ref = fw_group.new_file("usr/lib/lib#{name}.tbd")
  ref.source_tree = 'SDKROOT'
  ios.frameworks_build_phase.add_file_reference(ref)
end

# ---------------------------------------------------------------------------
# Embed Frameworks (code-sign the two dylibs into <App>.app/Frameworks).
# ---------------------------------------------------------------------------
embed = ios.new_copy_files_build_phase('Embed Frameworks')
embed.symbol_dst_subfolder_spec = :frameworks
DYLIBS.each do |name|
  bf = embed.add_file_reference(dylib_refs[name])
  bf.settings = { 'ATTRIBUTES' => ['CodeSignOnCopy'] }
end

# ---------------------------------------------------------------------------
# Resources / copy-files: engine Assets.bundle, Ruby stdlib, game assets.
# ---------------------------------------------------------------------------
res_group = proj.main_group.new_group('iOS Resources')

# Assets.bundle (engine shaders/fonts) from the Assets target's product.
assets_bf = template.copy_files_build_phases.flat_map(&:files)
                    .find { |bf| bf.file_ref&.display_name == 'Assets.bundle' }
if assets_bf
  ph = ios.new_copy_files_build_phase('Copy Assets Bundle')
  ph.symbol_dst_subfolder_spec = :resources
  bf = ph.add_file_reference(assets_bf.file_ref)
  bf.settings = { 'ATTRIBUTES' => ['CodeSignOnCopy', 'RemoveHeadersOnCopy'] }
end

# Ruby stdlib -> <App>.app/Ruby/3.1.0  (binding-mri.cpp looks here).
ruby_ref = res_group.new_reference("#{DEP_LIB}/ruby/3.1.0")
ruby_ref.last_known_file_type = 'folder'
ruby_ph = ios.new_copy_files_build_phase('Copy Ruby stdlib')
ruby_ph.symbol_dst_subfolder_spec = :resources
ruby_ph.dst_path = 'Ruby'
rbf = ruby_ph.add_file_reference(ruby_ref)
rbf.settings = { 'ATTRIBUTES' => ['CodeSignOnCopy'] }

# Another Red game assets -> <App>.app/game  (folder reference, copied as-is).
# Sibling of the repo: macos/ -> ../.. == mkxp-ios, then /game.
game_ref = res_group.new_reference('../../game')
game_ref.last_known_file_type = 'folder'
ios.resources_build_phase.add_file_reference(game_ref)

# ---------------------------------------------------------------------------
# Depend on the Assets target so Assets.bundle is built first.
# ---------------------------------------------------------------------------
assets_target = proj.targets.find { |t| t.name == 'Assets' }
ios.add_dependency(assets_target) if assets_target

proj.save

# ---------------------------------------------------------------------------
# Shared scheme so Z-iOS is selectable/runnable from Xcode's GUI.
# ---------------------------------------------------------------------------
scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(ios)
scheme.set_launch_target(ios)
scheme.save_as(proj.path, TARGET_NAME, true)
puts "Created #{TARGET_NAME}: #{ios.source_build_phase.files.count} sources, " \
     "#{ios.frameworks_build_phase.files.count} link items, " \
     "#{STATIC_LIBS.count} static libs, #{DYLIBS.count} embedded dylibs."
