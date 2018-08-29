# Start daemons
include_recipe "kube-hops::default"

private_ip = my_private_ip()
hostname = my_hostname()

# Create pki directories
directory node['kube-hops']['pki']['dir'] do
  owner node['kube-hops']['user']
  group node['kube-hops']['group']
  mode "700"
end

directory "#{node['kube-hops']['pki']['dir']}/etcd" do
  owner node['kube-hops']['user']
  group node['kube-hops']['group']
  mode "700"
end

# Fetch KubeCA certificate from Hopsworks
kube_hops_certs 'ca' do
  path        node['kube-hops']['pki']['dir']
  action :fetch_cert
  not_if { ::File.exist?("#{node['kube-hops']['pki']['dir']}/ca.crt") }
end

# Kube master certs
kube_hops_certs 'apiserver' do
  path        node['kube-hops']['pki']['dir']
  subject     "/CN=kube-apiserver"
  not_if      { ::File.exist?("#{node['kube-hops']['pki']['dir']}/apiserver.crt") }
end

kube_hops_certs 'apiserver-kubelet-client' do
  path        node['kube-hops']['pki']['dir']
  subject     "/CN=kube-apiserver-kubelet-client/O=system:masters"
  not_if      { ::File.exist?("#{node['kube-hops']['pki']['dir']}/apiserver-kubelet-client.crt") }
end

# ETCD certificates
# Etcd has its own separate CA.
# Template the CA configuration on the master
template "#{node['kube-hops']['pki']['dir']}/kube-ca.cnf" do
  source "kube-ca.cnf.erb"
  owner node['kube-hops']['user']
  group node['kube-hops']['group']
  variables ({
    'master_cluster_ip': private_ip,
    'master_hostname': hostname
  })
end

# Generate self signed ETCD CA certificate
kube_hops_certs 'ca' do
  path        "#{node['kube-hops']['pki']['dir']}/etcd"
  subject     "/CN=kube-etcd-ca"
  self_signed true
  not_if { ::File.exist?("#{node['kube-hops']['pki']['dir']}/etcd/ca.crt") }
end

kube_etcd_certs = ['server', 'peer', 'healthcheck-client']
kube_etcd_certs.each do |cert|
  kube_hops_certs cert do
    path      "#{node['kube-hops']['pki']['dir']}/etcd"
    subject   "/CN=kube-etcd-#{cert}"
    ca_path   "#{node['kube-hops']['pki']['dir']}/etcd"
    ca_name   "ca"
    not_if      { ::File.exist?("#{node['kube-hops']['pki']['dir']}/etcd/#{cert}.crt") }
  end
end

# Apiserver ETCD certificates
kube_hops_certs 'apiserver-etcd-client' do
  path        node['kube-hops']['pki']['dir']
  subject     "/CN=kube-apiserver-etcd-client"
  ca_path     "#{node['kube-hops']['pki']['dir']}/etcd"
  ca_name     "ca"
  not_if      { ::File.exist?("#{node['kube-hops']['pki']['dir']}/apiserver-etcd-client.crt") }
end

# Front proxy certificates
kube_hops_certs 'front-proxy-ca' do
  path        "#{node['kube-hops']['pki']['dir']}"
  subject     "/CN=front-proxy-ca"
  self_signed true
  not_if { ::File.exist?("#{node['kube-hops']['pki']['dir']}/front-proxy-ca.crt") }
end

kube_hops_certs 'front-proxy-client' do
  path        node['kube-hops']['pki']['dir']
  subject     "/CN=front-proxy-client"
  ca_path     "#{node['kube-hops']['pki']['dir']}"
  ca_name     "front-proxy-ca"
  not_if      { ::File.exist?("#{node['kube-hops']['pki']['dir']}/front-proxy-client.crt") }
end

file "#{node['kube-hops']['pki']['dir']}/front-proxy-ca.key" do
  action :delete
end

# Service account private/public key - Pub key doesn't have to be signed by a ca
kube_hops_key 'sa' do
  path        node['kube-hops']['pki']['dir']
  not_if      { ::File.exist?("#{node['kube-hops']['pki']['dir']}/sa.pub") }
end

# Generate configuration files containing key/certs for controller-manager and scheduler
components_conf = ['controller-manager', 'scheduler']
components_conf.each do |component|
  kube_hops_conf component do
    path        node['kube-hops']['conf_dir']
    subject     "/CN=system:kube-#{component}"
    master_ip   private_ip
    not_if      { ::File.exist?("#{node['kube-hops']['conf_dir']}/#{component}.conf") }
  end
end

# Generate configuration for kubelet
kube_hops_conf "kubelet" do
  path        node['kube-hops']['conf_dir']
  subject     "/CN=system:node:#{hostname}/O=system:nodes"
  master_ip   private_ip
  not_if      { ::File.exist?("#{node['kube-hops']['conf_dir']}/kubelet.conf") }
end

# Generate configuration file for admin
kube_hops_conf "admin" do
  path        node['kube-hops']['conf_dir']
  subject     "/CN=kubernetes-admin/O=system:masters"
  master_ip   private_ip
  not_if      { ::File.exist?("#{node['kube-hops']['conf_dir']}/admin.conf") }
end

# Template kubeadm configuration file
template "#{node['kube-hops']['conf_dir']}/kubeadm.conf" do
  source "kubeadm-config.erb"
  owner "root"
  group "root"
  mode "700"
  variables ({
    'api_address': private_ip
  })
end

bash 'init-master' do
  user 'root'
  group 'root'
  code <<-EOH
    kubeadm init --config #{node['kube-hops']['conf_dir']}/kubeadm.conf
  EOH
  only_if {Dir.empty?("#{node['kube-hops']['conf_dir']}/manifests") }
end

# Add configuration file in Kubernetes' user home to be able to access the cluster
directory "/home/#{node['kube-hops']['user']}/.kube" do
  user node['kube-hops']['user']
  group node['kube-hops']['group']
  action :create
end

remote_file "/home/#{node['kube-hops']['user']}/.kube/config" do
  source "file:///etc/kubernetes/admin.conf"
  user node['kube-hops']['user']
  group node['kube-hops']['group']
end

template "/home/#{node['kube-hops']['user']}/kube-flannel.yml" do
  source "kube-flannel.yml.erb"
  owner node['kube-hops']['user']
  group node['kube-hops']['group']
end

# Deploy overlay network
kube_hops_kubectl 'apply_flannel' do
  user node['kube-hops']['user']
  group node['kube-hops']['group']
  url "/home/#{node['kube-hops']['user']}/kube-flannel.yml"
end

# Untaint master
if node['kube-hops']['master']['untaint'].eql?("true")
  bash 'untaint_master' do
    user node['kube-hops']['user']
    group node['kube-hops']['group']
    code <<-EOH
      kubectl taint nodes --all node-role.kubernetes.io/master-
    EOH
  end
end

include_recipe "kube-hops::default_post"
