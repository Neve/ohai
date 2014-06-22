#
# Author:: Matt Ray (<matt@opscode.com>)
# Updated: Nick Stakanov  (<n.takanov@gmail.com>)
# Copyright:: Copyright (c) 2012 Opscode, Inc.
# License:: Apache License, Version 2.0
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

require 'ohai/mixin/ec2_metadata'

Ohai.plugin(:OpenstackV2) do
  provides "openstack_v2"

  include Ohai::Mixin::Ec2Metadata

  # Checks if required command exists and can be executed.
  #
  # === Args
  # command[String] -  command to check and run
  # arguments[String] - command arguments
  # user_path[String] - user defined PATHs to add to shell_out path.
  #
  # === Return
  # string:: Execution output If command binary exists
  # string:: "fail" if command execution return anything then 0
  def shell_out_safe(command, arguments='', user_paths='')
    so_path='/usr/local/bin:/bin:/usr/bin:/usr/local/sbin:/usr/sbin:/sbin'
    so_path<<user_paths
    # Checking if the command exists in standard paths to prevent
    # file not found errors
    so_check = shell_out("PATH=#{so_path} && bash -c 'command -v #{command}'")
    Ohai::Log.debug("  Ohai OpenStack ShellOut STATUS: #{so_check.exitstatus}")

    if so_check.exitstatus == 0
      so = shell_out("#{command} #{arguments}")
      if so.exitstatus == 0
        out = so.stdout.to_s.strip
      else
        Ohai::Log.warn("  Ohai OpenStack #{command} execution returned
           #{so_check.exitstatus}")
        out='fail'
      end
    else
      Ohai::Log.warn("  Ohai OpenStack #{command} Not found")
      out='fail'
    end
    return out
  end

  # Inserts Openstack API metadata into Openstack EC2 metadata hash
  #
  # === Args
  # target_hash[Hash] - hash to witch OPenStack API metadata should be added.
  #
  # selective[Boolean] - Default = True If default, only listed in required_keys
  # OpenStack API entries would be added. Otherwise all "metadata" hash will be
  # merged into "target_hash"
  #
  # === Return
  # target_hash:: joined Openstack Native and EC2 metadata.
  def fetch_openstack_api_metadata(target_hash, selective=:True)

    response = http_client.get('/openstack/latest/meta_data.json')
    unless response.code == '200'
      raise "Encountered error retrieving OpenStack user metadata
         (HTTP request returned #{response.code} response)"
    end

    json = StringIO.new(response.body)
    parser = Yajl::Parser.new
    metadata = parser.parse(json)

    # If selective == True insert selected values
    # merge metadata into target hash otherwise
    if selective == :True
      Ohai::Log.debug('  SELECTIVE INSERT')
      metadata.each_pair do |key, value|
        required_keys = %w(meta uuid public_keys name)
        if required_keys.include?(key)
          Ohai::Log.debug("    SELECTIVE INSERT: #{key} = #{value}")
          target_hash[key] = value
        end

      end
    else
      Ohai::Log.debug("  MERGING #{metadata}  INTO  #{target_hash}")
      target_hash.merge!(metadata)
    end
    target_hash
  end

  # Cleaning duplicated values in EC2 meta and OpenStack meta
  #
  # === Args
  # target_hash[Hash] - hash with EC2 metadata.
  #
  # === Return
  # target_hash[Hash] - target_hash with duplicated metadata removed.
  def cleanup_metadata(target_hash)
    redundant_keys= [/^public_keys_\d_openssh_key$/, /^name$/]

    redundant_keys.each do |entry|
      if (matched_key = target_hash.keys.grep(entry)).size > 0
        # Set of actions applied to duplicates.
        case matched_key[0]
        when redundant_keys[0]
          Ohai::Log.debug("  Deleting #{matched_key}")
          target_hash.delete(matched_key[0].to_s)
        when redundant_keys[1]
          if target_hash.has_key?('hostname')
            Ohai::Log.debug("  Renaming #{matched_key}")
            target_hash['full_hostname'] = target_hash['hostname']
            target_hash['hostname'] = target_hash['name']
            target_hash.delete('name')
          end

        else
          Ohai::Log.debug("  No action found for #{matched_key[0]}")
        end

      else
        Ohai::Log.debug('  No redundant entries in meta hash')
      end
    end
    Ohai::Log.debug("  Metadata : #{target_hash}")
    target_hash

  end

  collect_data do
    out = shell_out_safe('cat', '/sys/devices/virtual/dmi/id/product_name')
    Ohai::Log.debug(" GET #{out}")

    if hint?('openstack') || hint?('hp') || out.include?('OpenStack')
      Ohai::Log.info('  Ohai openstack plugin online')

      if hint?('hp')
        openstack['provider'] = 'hp'
      else
        openstack['provider'] = 'openstack'
      end

      # Adds openstack Mash
      openstack Mash.new

      if can_metadata_connect?(Ohai::Mixin::Ec2Metadata::EC2_METADATA_ADDR, 80)

        Ohai::Log.debug('  Connecting to the OpenStack EC2 metadata service')
        fetch_metadata.each { |k, v| openstack[k] = v }

        # Insert native OpenStack cloud metadata
        fetch_openstack_api_metadata(openstack, :False)
        # Remove duplicated entries from hash to reduce its size.
        cleanup_metadata(openstack)
      else
        Ohai::Log.debug('  Unable to connect to the OpenStack metadata service')
      end

      out = shell_out_safe('lscpu', ' | grep \'Hypervisor vendor\'')
      openstack['hypervisor'] = out.split(':')[1].strip unless out == 'fail'

      out = shell_out_safe('cat', '/sys/devices/virtual/dmi/id/product_version')
      openstack['cloud_version'] = out unless out == 'fail'

    else
      Ohai::Log.debug('NOT ohai openstack')
    end
  end
end

