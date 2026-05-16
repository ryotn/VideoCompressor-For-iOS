require 'xcodeproj'

project_path = './VideoCompressor.xcodeproj'
project = Xcodeproj::Project.new(project_path)
target = project.new_target(:application, 'VideoCompressor', :ios, '17.0')

main_group = project.main_group

def add_files(dir, group, target)
  Dir.glob(File.join(dir, '*')).each do |path|
    if File.directory?(path)
      sub_group = group.new_group(File.basename(path), File.basename(path))
      add_files(path, sub_group, target)
    elsif path.end_with?('.swift')
      file = group.new_file(File.basename(path))
      target.add_file_references([file])
    elsif path.end_with?('.xcassets')
      file = group.new_file(File.basename(path))
      target.resources_build_phase.add_file_reference(file)
    end
  end
end

app_group = main_group.new_group('VideoCompressor', 'VideoCompressor')
add_files('VideoCompressor', app_group, target)

# Add info.plist
target.build_configurations.each do |config|
  config.build_settings['INFOPLIST_FILE'] = 'VideoCompressor/Info.plist'
  config.build_settings['PRODUCT_BUNDLE_IDENTIFIER'] = 'com.ryotn.VideoCompressor'
  config.build_settings['SWIFT_VERSION'] = '5.0'
  config.build_settings['MARKETING_VERSION'] = '1.0'
  config.build_settings['CURRENT_PROJECT_VERSION'] = '1'
  config.build_settings['CODE_SIGN_ENTITLEMENTS'] = 'VideoCompressor/VideoCompressor.entitlements'
end

# Share Extension Target
share_target = project.new_target(:app_extension, 'ShareExtension', :ios, '17.0')
share_group = main_group.new_group('ShareExtension', 'ShareExtension')
add_files('ShareExtension', share_group, share_target)

share_target.build_configurations.each do |config|
  config.build_settings['INFOPLIST_FILE'] = 'ShareExtension/Info.plist'
  config.build_settings['PRODUCT_BUNDLE_IDENTIFIER'] = 'com.ryotn.VideoCompressor.ShareExtension'
  config.build_settings['SWIFT_VERSION'] = '5.0'
  config.build_settings['CODE_SIGN_ENTITLEMENTS'] = 'ShareExtension/ShareExtension.entitlements'
end

target.add_dependency(share_target)

embed_phase = target.new_copy_files_build_phase('Embed App Extensions')
embed_phase.dst_subfolder_spec = '13'
build_file = embed_phase.add_file_reference(share_target.product_reference)
build_file.settings = { 'ATTRIBUTES' => ['RemoveHeadersOnCopy'] }

project.save
