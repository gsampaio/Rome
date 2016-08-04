require 'fourflusher'

CONFIGURATION = "Release"
SIMULATORS = { 'iphonesimulator' => 'iPhone 5s',
               'appletvsimulator' => 'Apple TV 1080p',
               'watchsimulator' => 'Apple Watch - 38mm' }

SpecData = Struct.new(:name, :module_name)

def build_for_iosish_platform(sandbox, build_dir, target, device, simulator)
  deployment_target = target.platform_deployment_target
  target_label = target.cocoapods_target_label

  xcodebuild(sandbox, target_label, device, deployment_target)
  xcodebuild(sandbox, target_label, simulator, deployment_target)

  spec_names = target.specs.map { |spec| { "name" => spec.name, "module_name" => spec.root.module_name } }.uniq

  spec_names.each do |spec_data|
    root_name = spec_data["name"]
    module_name = spec_data["module_name"]

    executable_path = "#{build_dir}/#{root_name}"
    device_lib = "#{build_dir}/#{CONFIGURATION}-#{device}/#{root_name}/#{module_name}.framework/#{module_name}"
    device_framework_lib = File.dirname(device_lib)
    simulator_lib = "#{build_dir}/#{CONFIGURATION}-#{simulator}/#{root_name}/#{module_name}.framework/#{module_name}"

    next unless File.file?(device_lib) && File.file?(simulator_lib)

    lipo_log = `lipo -create -output "#{executable_path}" "#{device_lib}" "#{simulator_lib}"`
    puts lipo_log unless File.exist?(executable_path)

    FileUtils.mv executable_path, device_lib
    FileUtils.mv device_framework_lib, build_dir
    FileUtils.rm simulator_lib if File.file?(simulator_lib)
    FileUtils.rm device_lib if File.file?(device_lib)
  end
end

def xcodebuild(sandbox, target, sdk='macosx', deployment_target=nil)
  args = %W(-project #{sandbox.project_path.basename} -scheme #{target} -configuration #{CONFIGURATION} -sdk #{sdk})
  simulator = SIMULATORS[sdk]
  args += Fourflusher::SimControl.new.destination(simulator, deployment_target) unless simulator.nil?
  Pod::Executable.execute_command 'xcodebuild', args, true
end

Pod::HooksManager.register('cocoapods-rome', :post_install) do |installer_context|
  sandbox_root = Pathname(installer_context.sandbox_root)
  sandbox = Pod::Sandbox.new(sandbox_root)

  build_dir = sandbox_root.parent + 'build'
  destination = sandbox_root.parent + 'Rome'

  Pod::UI.puts 'Building frameworks'

  build_dir.rmtree if build_dir.directory?
  Dir.chdir(sandbox.project_path.dirname) do
    targets = installer_context.umbrella_targets.select { |t| t.specs.any? }
    targets.each do |target|
      case target.platform_name
      when :ios then build_for_iosish_platform(sandbox, build_dir, target, 'iphoneos', 'iphonesimulator')
      when :osx then xcodebuild(sandbox, target.cocoapods_target_label)
      when :tvos then build_for_iosish_platform(sandbox, build_dir, target, 'appletvos', 'appletvsimulator')
      when :watchos then build_for_iosish_platform(sandbox, build_dir, target, 'watchos', 'watchsimulator')
      else raise "Unknown platform '#{target.platform_name}'" end
    end
  end

  raise Pod::Informative, 'The build directory was not found in the expected location.' unless build_dir.directory?

  frameworks = Pathname.glob("#{build_dir}/**/*.framework").reject { |f| f.to_s =~ /Pods*\.framework/ }

  Pod::UI.puts "Built #{frameworks.count} #{'frameworks'.pluralize(frameworks.count)}"

  destination.rmtree if destination.directory?

  installer_context.umbrella_targets.each do |umbrella|
    umbrella.specs.each do |spec|
      consumer = spec.consumer(umbrella.platform_name)
      file_accessor = Pod::Sandbox::FileAccessor.new(sandbox.pod_dir(spec.root.name), consumer)
      frameworks += file_accessor.vendored_libraries
      frameworks += file_accessor.vendored_frameworks
    end
  end
  frameworks.uniq!

  Pod::UI.puts "Copying #{frameworks.count} #{'frameworks'.pluralize(frameworks.count)} " \
    "to `#{destination.relative_path_from Pathname.pwd}`"

  frameworks.each do |framework|
    FileUtils.mkdir_p destination
    FileUtils.cp_r framework, destination, :remove_destination => true
  end
  build_dir.rmtree if build_dir.directory?
end
