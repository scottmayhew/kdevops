# SPDX-License-Identifier: copyleft-next-0.3.1

TERRAFORM_EXTRA_VARS :=

KDEVOPS_PROVISION_METHOD		:= bringup_terraform
KDEVOPS_PROVISION_DESTROY_METHOD	:= destroy_terraform

export KDEVOPS_CLOUD_PROVIDER=aws
ifeq (y,$(CONFIG_TERRAFORM_AWS))
endif
ifeq (y,$(CONFIG_TERRAFORM_GCE))
export KDEVOPS_CLOUD_PROVIDER=gce
endif
ifeq (y,$(CONFIG_TERRAFORM_AZURE))
export KDEVOPS_CLOUD_PROVIDER=azure
endif
ifeq (y,$(CONFIG_TERRAFORM_OCI))
export KDEVOPS_CLOUD_PROVIDER=oci
endif
ifeq (y,$(CONFIG_TERRAFORM_OPENSTACK))
export KDEVOPS_CLOUD_PROVIDER=openstack
endif

KDEVOPS_NODES_TEMPLATE :=	$(KDEVOPS_NODES_ROLE_TEMPLATE_DIR)/terraform_nodes.tf.j2
KDEVOPS_NODES :=		terraform/$(KDEVOPS_CLOUD_PROVIDER)/nodes.tf

TERRAFORM_EXTRA_VARS += kdevops_enable_terraform='True'
TERRAFORM_EXTRA_VARS += kdevops_terraform_provider='$(KDEVOPS_CLOUD_PROVIDER)'

export KDEVOPS_PROVISIONED_SSH := $(KDEVOPS_PROVISIONED_SSH_DEFAULT_GUARD)

TFVARS_TEMPLATE_DIR=playbooks/roles/gen_tfvars/templates
TFVARS_FILE_NAME=terraform.tfvars
TFVARS_FILE_POSTFIX=$(TFVARS_FILE_NAME).j2

TFVARS_TEMPLATE=$(KDEVOPS_CLOUD_PROVIDER)/$(TFVARS_FILE_POSTFIX)
KDEVOPS_TFVARS_TEMPLATE=$(TFVARS_TEMPLATE_DIR)/$(KDEVOPS_CLOUD_PROVIDER)/$(TFVARS_FILE_POSTFIX)
KDEVOPS_TFVARS=terraform/$(KDEVOPS_CLOUD_PROVIDER)/$(TFVARS_FILE_NAME)

TERRAFORM_EXTRA_VARS += kdevops_terraform_tfvars_template='$(TFVARS_TEMPLATE)'
TERRAFORM_EXTRA_VARS += kdevops_terraform_tfvars_template_full_path='$(TOPDIR_PATH)/$(KDEVOPS_TFVARS_TEMPLATE)'
TERRAFORM_EXTRA_VARS += kdevops_terraform_tfvars='$(KDEVOPS_TFVARS)'

KDEVOPS_MRPROPER += terraform/$(KDEVOPS_CLOUD_PROVIDER)/.terraform.lock.hcl
KDEVOPS_MRPROPER += $(KDEVOPS_NODES)

DEFAULT_DEPS_REQS_EXTRA_VARS += $(KDEVOPS_TFVARS)

ifeq (y,$(CONFIG_TERRAFORM_AWS))
TERRAFORM_EXTRA_VARS += terraform_aws_profile=$(subst ",,$(CONFIG_TERRAFORM_AWS_PROFILE))
TERRAFORM_EXTRA_VARS += terraform_aws_region=$(subst ",,$(CONFIG_TERRAFORM_AWS_REGION))
TERRAFORM_EXTRA_VARS += terraform_aws_av_region=$(subst ",,$(CONFIG_TERRAFORM_AWS_AV_REGION))
TERRAFORM_EXTRA_VARS += terraform_aws_ami_owner=$(subst ",,$(CONFIG_TERRAFORM_AWS_AMI_OWNER))
TERRAFORM_EXTRA_VARS += terraform_aws_ns='$(CONFIG_TERRAFORM_AWS_NS)'
TERRAFORM_EXTRA_VARS += terraform_aws_virt_type=$(subst ",,$(CONFIG_TERRAFORM_AWS_VIRT_TYPE))
TERRAFORM_EXTRA_VARS += terraform_aws_instance_type=$(subst ",,$(CONFIG_TERRAFORM_AWS_INSTANCE_TYPE))

ifeq (y,$(CONFIG_TERRAFORM_AWS_ENABLE_EBS_VOLUMES))
TERRAFORM_EXTRA_VARS += terraform_aws_enable_ebs='True'
TERRAFORM_EXTRA_VARS += terraform_aws_ebs_num_volumes_per_instance=$(subst ",,$(CONFIG_TERRAFORM_AWS_EBS_NUM_VOLUMES_PER_INSTANCE))
TERRAFORM_EXTRA_VARS += terraform_aws_ebs_volume_size=$(subst ",,$(CONFIG_TERRAFORM_TERRAFORM_AWS_EBS_VOLUME_SIZE))
endif # CONFIG_TERRAFORM_AWS_ENABLE_EBS_VOLUMES

endif

ifeq (y,$(CONFIG_TERRAFORM_AZURE))
TERRAFORM_EXTRA_VARS += terraform_azure_resource_location=$(subst ",,$(CONFIG_TERRAFORM_AZURE_RESOURCE_LOCATION))
TERRAFORM_EXTRA_VARS += terraform_azure_vm_size=$(subst ",,$(CONFIG_TERRAFORM_AZURE_VM_SIZE))
TERRAFORM_EXTRA_VARS += terraform_azure_managed_disk_type=$(subst ",,$(CONFIG_TERRAFORM_AZURE_MANAGED_DISK_TYPE))
TERRAFORM_EXTRA_VARS += terraform_azure_image_publisher=$(subst ",,$(CONFIG_TERRAFORM_AZURE_IMAGE_PUBLISHER))
TERRAFORM_EXTRA_VARS += terraform_azure_image_offer=$(subst ",,$(CONFIG_TERRAFORM_AZURE_IMAGE_OFFER))
TERRAFORM_EXTRA_VARS += terraform_azure_image_sku=$(subst ",,$(CONFIG_TERRAFORM_AZURE_IMAGE_SKU))
TERRAFORM_EXTRA_VARS += terraform_azure_image_version=$(subst ",,$(CONFIG_TERRAFORM_AZURE_IMAGE_VERSION))
TERRAFORM_EXTRA_VARS += terraform_azure_client_cert_path=$(subst ",,$(CONFIG_TERRAFORM_AZURE_CLIENT_CERT_PATH))
TERRAFORM_EXTRA_VARS += terraform_azure_client_cert_passwd=$(subst ",,$(CONFIG_TERRAFORM_AZURE_CLIENT_CERT_PASSWD))
TERRAFORM_EXTRA_VARS += terraform_azure_application_id=$(subst ",,$(CONFIG_TERRAFORM_AZURE_APPLICATION_ID))
TERRAFORM_EXTRA_VARS += terraform_azure_subscription_id=$(subst ",,$(CONFIG_TERRAFORM_AZURE_SUBSCRIPTION_ID))
TERRAFORM_EXTRA_VARS += terraform_azure_tenant_id=$(subst ",,$(CONFIG_TERRAFORM_AZURE_TENANT_ID))
endif

ifeq (y,$(CONFIG_TERRAFORM_GCE))
TERRAFORM_EXTRA_VARS += terraform_gce_project_name=$(subst ",,$(CONFIG_TERRAFORM_GCE_PROJECT_NAME))
TERRAFORM_EXTRA_VARS += terraform_gce_region=$(subst ",,$(CONFIG_TERRAFORM_GCE_REGION_LOCATION))
TERRAFORM_EXTRA_VARS += terraform_gce_machine_type=$(subst ",,$(CONFIG_TERRAFORM_GCE_MACHINE_TYPE))
TERRAFORM_EXTRA_VARS += terraform_gce_scatch_disk_type=$(subst ",,$(CONFIG_TERRAFORM_GCE_SCRATCH_DISK_INTERFACE))
TERRAFORM_EXTRA_VARS += terraform_gce_image_name=$(subst ",,$(CONFIG_TERRAFORM_GCE_IMAGE))
TERRAFORM_EXTRA_VARS += terraform_gce_credentials=$(subst ",,$(CONFIG_TERRAFORM_GCE_JSON_CREDENTIALS_PATH))
endif

ifeq (y,$(CONFIG_TERRAFORM_OCI))
TERRAFORM_EXTRA_VARS += terraform_oci_region=$(subst ",,$(CONFIG_TERRAFORM_OCI_REGION))
TERRAFORM_EXTRA_VARS += terraform_oci_tenancy_ocid=$(subst ",,$(CONFIG_TERRAFORM_OCI_TENANCY_OCID))
TERRAFORM_EXTRA_VARS += terraform_oci_user_ocid=$(subst ",,$(CONFIG_TERRAFORM_OCI_USER_OCID))
TERRAFORM_EXTRA_VARS += terraform_oci_user_private_key_path=$(subst ",,$(CONFIG_TERRAFORM_OCI_USER_PRIVATE_KEY_PATH))
TERRAFORM_EXTRA_VARS += terraform_oci_user_fingerprint=$(subst ",,$(CONFIG_TERRAFORM_OCI_USER_FINGERPRINT))
TERRAFORM_EXTRA_VARS += terraform_oci_availablity_domain=$(subst ",,$(CONFIG_TERRAFORM_OCI_AVAILABLITY_DOMAIN))
TERRAFORM_EXTRA_VARS += terraform_oci_compartment_ocid=$(subst ",,$(CONFIG_TERRAFORM_OCI_COMPARTMENT_OCID))
TERRAFORM_EXTRA_VARS += terraform_oci_shape=$(subst ",,$(CONFIG_TERRAFORM_OCI_SHAPE))
TERRAFORM_EXTRA_VARS += terraform_oci_instance_flex_ocpus=$(subst ",,$(CONFIG_TERRAFORM_OCI_INSTANCE_FLEX_OCPUS))
TERRAFORM_EXTRA_VARS += terraform_oci_instance_flex_memory_in_gbs=$(subst ",,$(CONFIG_TERRAFORM_OCI_INSTANCE_FLEX_MEMORY_IN_GBS))
TERRAFORM_EXTRA_VARS += terraform_oci_os_image_ocid=$(subst ",,$(CONFIG_TERRAFORM_OCI_OS_IMAGE_OCID))
ifeq (y, $(CONFIG_TERRAFORM_OCI_ASSIGN_PUBLIC_IP))
TERRAFORM_EXTRA_VARS += terraform_oci_assign_public_ip=true
else
TERRAFORM_EXTRA_VARS += terraform_oci_assign_public_ip=false
endif
TERRAFORM_EXTRA_VARS += terraform_oci_subnet_ocid=$(subst ",,$(CONFIG_TERRAFORM_OCI_SUBNET_OCID))
TERRAFORM_EXTRA_VARS += terraform_oci_data_volume_display_name=$(subst ",,$(CONFIG_TERRAFORM_OCI_DATA_VOLUME_DISPLAY_NAME))
TERRAFORM_EXTRA_VARS += terraform_oci_data_volume_device_file_name=$(subst ",,$(CONFIG_TERRAFORM_OCI_DATA_VOLUME_DEVICE_FILE_NAME))
TERRAFORM_EXTRA_VARS += terraform_oci_sparse_volume_display_name=$(subst ",,$(CONFIG_TERRAFORM_OCI_SPARSE_VOLUME_DISPLAY_NAME))
TERRAFORM_EXTRA_VARS += terraform_oci_sparse_volume_device_file_name=$(subst ",,$(CONFIG_TERRAFORM_OCI_SPARSE_VOLUME_DEVICE_FILE_NAME))
endif

ifeq (y,$(CONFIG_TERRAFORM_OPENSTACK))
TERRAFORM_EXTRA_VARS += terraform_openstack_cloud_name=$(subst ",,$(CONFIG_TERRAFORM_TERRAFORM_OPENSTACK_CLOUD_NAME))
TERRAFORM_EXTRA_VARS += terraform_openstack_instance_prefix=$(subst ",,$(CONFIG_TERRAFORM_TERRAFORM_OPENSTACK_INSTANCE_PREFIX))
TERRAFORM_EXTRA_VARS += terraform_openstack_flavor=$(subst ",,$(CONFIG_TERRAFORM_OPENSTACK_FLAVOR))
TERRAFORM_EXTRA_VARS += terraform_openstack_ssh_pubkey_name=$(subst ",,$(CONFIG_TERRAFORM_OPENSTACK_SSH_PUBKEY_NAME))
TERRAFORM_EXTRA_VARS += terraform_openstack_public_network_name=$(subst ",,$(CONFIG_TERRAFORM_OPENSTACK_PUBLIC_NETWORK_NAME))

ANSIBLE_EXTRA_ARGS_SEPARATED += terraform_openstack_image_name=$(subst $(space),+,$(CONFIG_TERRAFORM_OPENSTACK_IMAGE_NAME))
endif

ifeq (y,$(CONFIG_TERRAFORM_PRIVATE_NET))
TERRAFORM_EXTRA_VARS += terraform_private_net_enabled='true'
TERRAFORM_EXTRA_VARS += terraform_private_net_prefix=$(subst ",,$(CONFIG_TERRAFORM_PRIVATE_NET_PREFIX))
TERRAFORM_EXTRA_VARS += terraform_private_net_mask=$(subst ",,$(CONFIG_TERRAFORM_PRIVATE_NET_MASK))
endif

SSH_CONFIG_USER:=$(subst ",,$(CONFIG_TERRAFORM_SSH_CONFIG_USER))
# XXX: add support to auto-infer in devconfig role as we did with the bootlinux
# role. Then we can re-use the same infer_uid_and_group=True variable and
# we could then remove this entry.
TERRAFORM_EXTRA_VARS += data_home_dir=/home/${SSH_CONFIG_USER}

ifeq (y,$(CONFIG_KDEVOPS_SSH_CONFIG_UPDATE))
TERRAFORM_EXTRA_VARS += kdevops_terraform_ssh_config_update='True'

ifeq (y,$(CONFIG_KDEVOPS_SSH_CONFIG_UPDATE_STRICT))
TERRAFORM_EXTRA_VARS += kdevops_terraform_ssh_config_update_strict='True'
endif

ifeq (y,$(CONFIG_KDEVOPS_SSH_CONFIG_UPDATE_BACKUP))
TERRAFORM_EXTRA_VARS += kdevops_terraform_ssh_config_update_backup='True'
endif

endif # CONFIG_KDEVOPS_SSH_CONFIG_UPDATE

export KDEVOPS_SSH_PUBKEY:=$(shell realpath $(subst ",,$(CONFIG_TERRAFORM_SSH_CONFIG_PUBKEY_FILE)))
TERRAFORM_EXTRA_VARS += kdevops_terraform_ssh_config_pubkey_file='$(KDEVOPS_SSH_PUBKEY)'
TERRAFORM_EXTRA_VARS += kdevops_terraform_ssh_config_user='$(SSH_CONFIG_USER)'

ifeq (y,$(CONFIG_TERRAFORM_SSH_CONFIG_GENKEY))
export KDEVOPS_SSH_PRIVKEY:=$(basename $(KDEVOPS_SSH_PUBKEY))
TERRAFORM_EXTRA_VARS += kdevops_terraform_ssh_config_privkey_file='$(KDEVOPS_SSH_PRIVKEY)'

ifeq (y,$(CONFIG_TERRAFORM_SSH_CONFIG_GENKEY_OVERWRITE))
DEFAULT_DEPS += remove-ssh-key
TERRAFORM_EXTRA_VARS += kdevops_terraform_ssh_config_genkey_overwrite='True'
endif

DEFAULT_DEPS += $(KDEVOPS_SSH_PRIVKEY)
endif # CONFIG_TERRAFORM_SSH_CONFIG_GENKEY

ANSIBLE_EXTRA_ARGS += $(TERRAFORM_EXTRA_VARS)

bringup_terraform:
	$(Q)ansible-playbook $(ANSIBLE_VERBOSE) \
		--connection=local --inventory localhost, \
		playbooks/terraform.yml --tags bringup \
		--extra-vars=@./extra_vars.yaml \
		-e 'ansible_python_interpreter=/usr/bin/python3'

$(KDEVOPS_PROVISIONED_SSH):
	$(Q)ansible-playbook $(ANSIBLE_VERBOSE) \
		-i $(KDEVOPS_HOSTFILE) \
		playbooks/terraform.yml --tags ssh \
		--extra-vars=@./extra_vars.yaml \
		-e 'ansible_python_interpreter=/usr/bin/python3'
	$(Q)touch $(KDEVOPS_PROVISIONED_SSH)

destroy_terraform:
	$(Q)ansible-playbook $(ANSIBLE_VERBOSE) \
		--connection=local -i $(KDEVOPS_HOSTFILE) \
		playbooks/terraform.yml --tags destroy \
		--extra-vars=@./extra_vars.yaml \
		-e 'ansible_python_interpreter=/usr/bin/python3'
	$(Q)rm -f $(KDEVOPS_PROVISIONED_SSH) $(KDEVOPS_PROVISIONED_DEVCONFIG)

$(KDEVOPS_TFVARS): $(KDEVOPS_TFVARS_TEMPLATE) .config
	$(Q)ansible-playbook $(ANSIBLE_VERBOSE) --connection=local \
		--inventory localhost, \
		$(KDEVOPS_PLAYBOOKS_DIR)/gen_tfvars.yml \
		-e 'ansible_python_interpreter=/usr/bin/python3' \
		--extra-vars=@./extra_vars.yaml
