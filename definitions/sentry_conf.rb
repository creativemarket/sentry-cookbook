# -*- coding: utf-8 -*-
#
# Cookbook Name:: sentry cookbook
# Definition:: sentry_conf
#
# Making sentry configuration file
#
# :copyright: (c) 2012 - 2013 by Alexandr Lispython (alex@obout.ru).
# :license: BSD, see LICENSE for more details.
# :github: http://github.com/Lispython/sentry-cookbook
#

class Chef::Recipe
  include Chef::Mixin::DeepMerge
end

define :sentry_conf,
       :name => nil,
       :template => "sentry.conf.erb",
       :virtualenv_dir => nil,
       :user => "sentry",
       :group => "sentry",
       :config => nil,
       :superusers => [],
       :variables => {},
       :settings => {} do

  Chef::Log.info("Making sentry config for: #{params[:name]}")

  include_recipe "python::virtualenv"
  include_recipe "python::pip"
  include_recipe "sentry::default"

  virtualenv_dir = params[:virtualenv_dir] or node["sentry"]["virtualenv"]
  bin_sentry = "#{virtualenv_dir}/bin/sentry"

  #settings_variables = Chef::Mixin::DeepMerge.deep_merge!(node[:sentry][:settings].to_hash, params[:settings])

  settings_variables = params[:settings]
  config = params[:config] || node["sentry"]["config"]
  settings_variables["config"] = config

  # Making application directory (if installing from pip)
  if node["sentry"]["install_method"] == "package"
    Chef::Log.info("Making directory for virtualenv: #{virtualenv_dir}")
    directory virtualenv_dir do
      owner params[:user]
      group params[:group]
      mode 0777
      recursive true
      action :create
    end
  end

  # Creating sentry config
  Chef::Log.info("Making config #{config}")
  template config do
    owner params[:user]
    group params[:group]
    source params[:template]
    mode 0777
    variables(settings_variables.to_hash)
  end

  # Create virtualenv structure
  Chef::Log.info("Making virtualenv: #{virtualenv_dir}")
  python_virtualenv virtualenv_dir do
    owner params[:user]
    group params[:group]
    action :create
  end

  # Install from source
  if node["sentry"]["install_method"] == 'source'

    # install dependencies
    bash "sentry_dependencies" do
      cwd virtualenv_dir
      user "root"
      code <<-EOH
      source #{virtualenv_dir}/bin/activate &&
      easy_install -UZ #{virtualenv_dir} > #{virtualenv_dir}/deps.txt
      EOH
    end

    # make
    include_recipe "build-essential::default"
    include_recipe "nodejs::default"
    include_recipe "nodejs::npm"
    bash "make_source" do
      cwd virtualenv_dir
      user "root"
      code <<-EOH
      make
      EOH
    end

    bin_sentry = "/usr/local/bin/sentry"
  end

  # Install sentry from pip package
  if node["sentry"]["install_method"] == 'package'
    python_pip "sentry" do
      provider Chef::Provider::PythonPip
      user params[:user]
      group params[:group]
      virtualenv virtualenv_dir
      version node["sentry"]["version"]
      action :install
    end
  end

  # Install database drivers
  node['sentry']['settings']['databases'].each do |key, db_options|
    driver_name = nil
    if db_options['ENGINE'] == 'django.db.backends.postgresql_psycopg2'
      driver_name = 'psycopg2'
    elsif db_options['ENGINE'] == 'django.db.backends.mysql'
      driver_name = 'MySQLdb'
    elsif db_options['ENGINE'] == 'django.db.backends.oracle'
      driver_name = 'cx_Oracle'
    else
      raise "You need specify database ENGINE"
    end

    if driver_name
      Chef::Log.info("Install #{driver_name} driver")
      package "libpq-dev" do action :install end
      package "python-dev" do action :install end
      package "python-psycopg2" do action :install end
      python_pip driver_name do
        user "root"
        provider Chef::Provider::PythonPip
        virtualenv virtualenv_dir
        action :install
      end
    end
  end

  # Install third party plugins
  node["sentry"]["settings"]["third_party_plugins"].each do |item|
    python_pip item["pypi_name"] do
      user params[:user]
      group params[:group]
      provider Chef::Provider::PythonPip
      virtualenv virtualenv_dir
      if item.has_key?("version")
        version item["version"]
      end
      action :install
    end
  end

  # Set permissions
  bash "chown virtualenv" do
    code <<-EOH
    chown -R #{params['user']}:#{params['group']} #{virtualenv_dir}
    EOH
  end

  # Create database
  node['sentry']['settings']['databases'].each do |key, db_options|
    bash "add_table" do
      ignore_failure true
      if db_options['ENGINE'] == 'django.db.backends.postgresql_psycopg2'
        user "postgres"
        code <<-EOH
        createdb --encoding=utf-8 --locale=en_US.utf8 --template template0 #{db_options['NAME']}
        EOH
      elsif db_options['ENGINE'] == 'django.db.backends.mysql'
        user "root"
        code <<-EOH
        mysql -u #{db_options['USER']} -p #{db_options['PASSWORD']} -e "CREATE DATABASE #{db_options['NAME']}"
        EOH
      else
        raise "Unable to create #{db_options['NAME']} schema for #{db_options['ENGINE']} engine."
      end
    end
  end

  # Run migrations / setup tables
  # sentry --config=/etc/sentry.conf.py upgrade
  bash "upgrade sentry" do
    cwd virtualenv_dir
    user params[:user]
    group params[:group]
    code <<-EOH
    . #{virtualenv_dir}/bin/activate &&
    #{bin_sentry} --config=#{config} upgrade --noinput &&
    deactivate
    EOH
  end

  # Create superusers script
  template node["sentry"]["superuser_creator_script"] do
    owner params[:user]
    group params[:group]

    source "superuser_creator.py.erb"
    variables(:config => config,
              :superusers => params[:superusers] || node["sentry"]["superusers"],
              :virtualenv => virtualenv_dir)
  end

  # sentry --config=/etc/sentry.conf.py createsuperuser
  bash "create sentry superusers" do
    user params[:user]
    group params[:group]
    cwd virtualenv_dir

    code <<-EOH
    . #{virtualenv_dir}/bin/activate &&
    #{virtualenv_dir}/bin/python #{node['sentry']['superuser_creator_script']} &&
    deactivate
    EOH
  end

  file node['sentry']['superuser_creator_script'] do
    action :delete
  end

end
