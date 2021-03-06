#
# Cookbook Name:: deployment
# Recipe:: default
#
# Copyright 2011, VMware
#

node[:nats_server][:host] ||= cf_local_ip
node[:ccdb][:host] ||= cf_local_ip
node[:postgresql][:host] ||= cf_local_ip

[node[:deployment][:home], File.join(node[:deployment][:home], "deploy"), node[:deployment][:log_path],
 File.join(node[:deployment][:home], "sys", "log"), node[:deployment][:config_path],
 File.join(node[:deployment][:config_path], "staging")].each do |dir|
  directory dir do
    owner node[:deployment][:user]
    group node[:deployment][:group]
    mode "0755"
    recursive true
    action :create
  end
end

var_vcap = File.join("", "var", "vcap")
[var_vcap, File.join(var_vcap, "sys"), File.join(var_vcap, "db"), File.join(var_vcap, "services"),
 File.join(var_vcap, "data"), File.join(var_vcap, "data", "cloud_controller"),
 File.join(var_vcap, "sys", "log"), File.join(var_vcap, "data", "cloud_controller", "tmp"),
 File.join(var_vcap, "data", "cloud_controller", "staging"),
 File.join(var_vcap, "data", "db"), File.join("", "var", "vcap.local"),
 File.join("", "var", "vcap.local", "staging")].each do |dir|
  directory dir do
    owner node[:deployment][:user]
    group node[:deployment][:group]
    mode "0755"
    recursive true
    action :create
  end
end

template node[:deployment][:info_file] do
  path node[:deployment][:info_file]
  source "deployment_info.json.erb"
  owner node[:deployment][:user]
  mode 0644
  variables({
    :name => node[:deployment][:name],
    :ruby_bin_dir => File.join(node[:ruby][:path], "bin"),
    :cloudfoundry_path => node[:cloudfoundry][:path],
    :deployment_log_path => node[:deployment][:log_path]
  })
end

file node[:deployment][:local_run_profile] do
  owner node[:deployment][:user]
  group node[:deployment][:group]
  content <<-EOH
    export PATH=#{node[:ruby][:path]}/bin:`#{node[:ruby][:path]}/bin/gem env gempath`/bin:$PATH
    export CLOUD_FOUNDRY_CONFIG_PATH=#{node[:deployment][:config_path]}
  EOH
end

file node[:deployment][:cf_deployment_start] do
  owner node[:deployment][:user]
  group node[:deployment][:group]
  content <<-EOH
      #!/usr/bin/env ruby
      require 'rubygems'
      require 'json'
      require 'yaml'
      require 'uri'
      require 'socket'
      
      A_ROOT_SERVER = '198.41.0.4'
      def cf_local_ip(route = A_ROOT_SERVER)
        route ||= A_ROOT_SERVER
        orig, Socket.do_not_reverse_lookup = Socket.do_not_reverse_lookup, true
        UDPSocket.open {|s| s.connect(route, 1); s.addr.last }
      ensure
        Socket.do_not_reverse_lookup = orig
      end
      
      def configurePostgresql(ip)
        if !File.exist?('/etc/postgresql')
          return
        end
        Dir.chdir('/etc/postgresql') do
          Dir.glob(File.join("**","postgresql.conf")){|filename|
            content =""
            IO.foreach(filename) do |line|
              if line =~ /^\s*listen_addresses\s*=.*/
               line = "listen_addresses = '\#{ip},localhost'\#{$/}"
              end
              content.concat(line)              
            end    
            File.open(filename, 'w') {|f| f.write(content) }
            return
          }
        end  
      end
      
      file = File.open(File.expand_path("#{ENV["HOME"]}/.cloudfoundry_deployment_target"), "rb")
      cf_local_dep = JSON.parse!(file.read)
      cf_home = cf_local_dep['cloudfoundry_home']
      local_dep_name = cf_local_dep['deployment_name']
      config_dir = "\#{cf_home}/.deployments/\#{local_dep_name}/config"
      begin
        public_ip = `wget -qO -  http://169.254.169.254/latest/meta-data/public-ipv4`
        local_ip = `wget -qO -  http://169.254.169.254/latest/meta-data/local-ipv4`
        instance_id = `wget -qO -  http://169.254.169.254/latest/meta-data/instance-id`
        user_data = JSON.parse(`wget -qO -  http://169.254.169.254/latest/user-data`)
      rescue
        public_ip = local_ip = cf_local_ip
        instance_id = 'local'
        user_data = {:landscapeid => 'local'}
        $stderr.puts "Unable to fetch user data. Are you running on EC2 cloud?"  
      end
      configurePostgresql(local_ip)
      Dir.chdir(config_dir) do
        Dir.glob("*.yml").each{|file|
          comp_config = YAML.load(File.read(file))
          comp_config['instance_id'] = instance_id
          if !user_data['landscapeid'].nil?
           comp_config['landscape_id'] = user_data['landscapeid']
          end
          if !user_data['landscape.val.dea_image'].nil?
           comp_config['dea_image'] = user_data['landscape.val.dea_image']
          end
          
          if !user_data['landscape.val.main_image'].nil?
           comp_config['main_image'] = user_data['landscape.val.main_image']
          end
          
          if !user_data['landscape.val.router_image'].nil?
           comp_config['router_image'] = user_data['landscape.val.router_image']
          end
          if !user_data['landscape.val.provider_uri'].nil?
           comp_config['provider_uri'] = user_data['landscape.val.provider_uri']
          end
          if !user_data['loadbalancer_name'].nil? && !comp_config['loadbalancer'].nil?             
           comp_config['loadbalancer'] = user_data['loadbalancer_name']
          end
          if !comp_config['local_route'].nil?
            comp_config['local_route'] = local_ip
          end
          if !comp_config['ip_route'].nil?
            comp_config['ip_route'] = local_ip
          end
          mbus = URI.parse(comp_config['mbus'])
          puts mbus
          if !mbus.nil? && !user_data.nil? && !user_data['landscape.ref.Main'].nil?
          #  mbus.host = user_data['message_bus']['host']
          #  mbus.port = user_data['message_bus']['port'].to_i
             mbus.host = user_data['landscape.ref.Main']
             mbus.port = 4222
             comp_config['mbus'] = "\#{mbus}"
          elsif !mbus.nil?
            mbus.host = 'localhost'
            mbus.port = 4222
            comp_config['mbus'] = "\#{mbus}"
          end
          database_environment = comp_config['database_environment']
          if database_environment
            env = comp_config['rails_environment'] || 'production'
            if user_data['landscape.ref.CCDB']
              database_environment[env]['host'] = user_data['landscape.ref.CCDB'] 
            else
              database_environment[env]['host'] = 'localhost'
            end           
          end
          
          File.open(file,'w+') {|out|
            YAML.dump(comp_config,out)
          }
        }
      end
      
      #Special handling for nats config (Let it listen on all ports by default)
      if File.exists?(File.join(config_dir,"nats_server","nats_server.yml"))
        comp_config = YAML.load(File.read("\#{config_dir}/nats_server/nats_server.yml"))
        comp_config['net'] = '0.0.0.0'
        File.open("\#{config_dir}/nats_server/nats_server.yml",'w+') {|out|
              YAML.dump(comp_config,out)
         }
      end
      exec("sudo \#{cf_home}/vcap/dev_setup/bin/vcap_dev -d \#{cf_home} -n \#{local_dep_name} start")
  EOH
end
file node[:deployment][:sample_rc_local] do
  owner node[:deployment][:user]
  group node[:deployment][:group]
  content <<-EOH
    . #{node[:deployment][:profile]}
    ruby #{node[:deployment][:cf_deployment_start]} 2> #{ENV["HOME"]}/cferror.txt
    exit 0
  EOH
end
