#
# Cookbook Name:: mwser-opt
# Recipe:: default
#
# Copyright (C) 2015 UC Regents
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# require chef-vault
chef_gem 'chef-vault'
require 'chef-vault'

# some basic package deps. only tested on rhel family.
package 'git'

unless node['fqdn'] == 'onlinepoll.ucla.edu'
  fqdn = 'staging.onlinepoll.ucla.edu'
  app_name = 'staging'
  app_revision = 'master'
  rails_env = 'staging'
  port = 3002
end

# install mysql
db_root_obj = ChefVault::Item.load("passwords", "db_root")
db_root = db_root_obj[node['fqdn']]
db_opt_obj = ChefVault::Item.load("passwords", "opt")
db_opt = db_opt_obj[fqdn]
mysql_service 'default' do
  port '3306'
  version '5.6'
  initial_root_password db_root
  action [:create, :start]
end

mysql_connection = {
  :host => '127.0.0.1',
  :port => 3306,
  :username => 'root',
  :password => db_root
}

# set up opt db
mysql2_chef_gem 'default'
mysql_database 'opt' do
  connection mysql_connection
  action :create
end
mysql_database_user 'opt' do
  connection mysql_connection
  password db_opt
  database_name 'opt'
  action [:create,:grant]
end

# install nginx
node.set['nginx']['default_site_enabled'] = false
node.set['nginx']['install_method'] = 'package'
include_recipe 'nginx::repo'
include_recipe 'nginx'

directory '/etc/ssl/private' do
  recursive true
end

# add SSL certs to box
ssl_key_cert = ChefVault::Item.load('ssl', fqdn) # gets ssl cert from chef-vault
file "/etc/ssl/certs/#{fqdn}.crt" do
  owner 'root'
  group 'root'
  mode '0777'
  content ssl_key_cert['cert']
  notifies :reload, 'service[nginx]', :delayed
end
file "/etc/ssl/private/#{fqdn}.key" do
  owner 'root'
  group 'root'
  mode '0600'
  content ssl_key_cert['key']
  notifies :reload, 'service[nginx]', :delayed
end

# nginx conf
template '/etc/nginx/sites-available/opt' do
  source 'opt.conf.erb'
  mode '0775'
  action :create
  variables(
    app_name: app_name,
    fqdn: fqdn,
    port: 3002,
    path: '/var/www/', # not used.
    # bridge_enabled: bridge_enabled
  )
  notifies :reload, 'service[nginx]', :delayed
end
nginx_site 'opt' do
  action :enable
end

# install ruby with rbenv, npm, git
node.default['rbenv']['rubies'] = ['2.2.3']
include_recipe 'ruby_build'
include_recipe 'ruby_rbenv::system'
include_recipe 'nodejs::npm'
rbenv_global '2.2.3'
rbenv_gem 'bundle'

opt_deploy_key = ChefVault::Item.load('deploy', 'opt') # gets ssl cert from chef-vault

# set up opt!
opt app_name do
  revision app_revision
  port 3002
  db_password db_opt
  deploy_path '/var/opt'
  bundler_path '/usr/local/rbenv/shims'
  rails_env rails_env
  deploy_key opt_deploy_key['private']
  # assumes es_host is localhost!
end
