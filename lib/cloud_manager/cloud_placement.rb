module VHelper::CloudManager
  class VHelperCloud
    REMAIDER_DISK_SIZE = ResourceInfo::DISK_CHANGE_TIMES * 10
    HOST_SYS_DISK_SIZE = ResourceInfo::DISK_CHANGE_TIMES * 2
    def cluster_placement(dc_resource, vm_groups_input, vm_groups_existed, cluster_info)
      vm_placement = []
      if vm_groups_existed.size > 0
        #TODO add changed placement logical
      end

      #TODO add placement logical here
      cluster = dc_resource.clusters.values.first
      resource_pools = cluster.resource_pools

      @logger.debug("#{cluster.hosts.pretty_inspect}")
      vm_groups_input.each_value { |vm_group|
        hosts = cluster.hosts.values
        @logger.debug("#{hosts.class},#{hosts.pretty_inspect}")
        #hosts.shuffle!

        cur_rp = nil
        resource_pools.each_value { |rp|
          next if rp.limit_mem != -1 && (rp.real_free_memory < vm_group.req_info.mem)
          cur_rp = rp
          break
        }
        raise "No resources for placement!" if cur_rp.nil?

        hosts.each { |host|
          host.place_share_datastores = host.share_datastores.values
          host.place_local_datastores = host.local_datastores.values
          host.place_share_datastores.shuffle!
          host.place_local_datastores.shuffle!
        }
        group_place = []
        vm_group.instances.times { |num|
          vm_name = gen_vm_name(cluster_info["name"], vm_group.name, num)
          @logger.debug("vm_name: #{vm_name}")
          vm = VHelper::CloudManager::VmInfo.new(vm_name, @logger)
          vm.host_name = nil
          while !hosts.empty? 
            hosts.rotate!
            host = hosts[0]

            @logger.debug("host :#{host}")
            req_mem = vm_group.req_info.mem
            if host.real_free_memory < req_mem
              @logger.debug("#{host.name} haven't enough memory for #{vm_name} req:#{req_mem}, host has :#{host.real_free_space}.")
              hosts.shift
              next
            end
            #The host is suitable for this VM
            host.place_share_datastores.rotate!

            #Get the sys_datastore for clone
            sys_datastore = nil 
            host.place_share_datastores.delete_if {|datastore| datastore.real_free_space < REMAIDER_DISK_SIZE }
            host.place_share_datastores.each { |datastore|
              if datastore.real_free_space > REMAIDER_DISK_SIZE 
                datastore.unaccounted_space += HOST_SYS_DISK_SIZE
                sys_datastore = datastore
                break
              end
            }
            if sys_datastore.nil?
              hosts.shift
              next
            end
            @logger.debug("get sys datastore :#{sys_datastore.name}")

            #Get the datastore for this vm
            used_datastores = []
            req_size = vm_group.req_info.disk_size
            host.place_share_datastores.delete_if {|datastore| datastore.real_free_space < REMAIDER_DISK_SIZE }
            host.place_share_datastores.each do |datastore|
              next if datastore.real_free_space < REMAIDER_DISK_SIZE
              free_size = datastore.real_free_space - REMAIDER_DISK_SIZE
              free_size = req_size if free_size > req_size 
              used_datastores << {:datastore => datastore, :size=>free_size}
              req_size -= free_size.to_i
              break if req_size.to_i <=0 
            end
            if req_size > 0
              #TODO no disk space for this vm
              vm.error_msg = "No enough disk for #{vm_name}."
              @logger.debug("ERROR: #{vm.error_msg}")
              hosts.shift
              next
            end

            cur_rp.unaccounted_memory += req_mem
            host.unaccounted_memory += req_mem

            vm.host_name  = host.name 
            vm.host_mob   = host.mob
            vm.req_rp     = vm_group.req_info

            vm.sys_datastore_moid = sys_datastore.mob
            vm.resource_pool_moid = cur_rp.mob
            vm.template_id = vm_group.req_info.template_id
            @logger.debug("vm.template_id:#{vm.template_id}")

            used_datastores.each { |datastore|
              fullpath = "[#{datastore[:datastore].name}] #{vm_name}/data.vmdk" 
              datastore[:datastore].unaccounted_space += datastore[:size].to_i
              vm.disk_add(datastore[:size].to_i, fullpath)
            }
            vm.error_msg = nil
            break
          end
          @vm_lock.synchronize { @preparing_vms[vm.name] = vm }
          group_place << vm
          if vm.error_msg
            #NO resource for this vm_group
            vm.error_msg << "The group also has no resources to alloced"
            @logger.debug("vm can not get resources :#{vm.error_msg} ")
          end
        }
        vm_placement << group_place
      }

      vm_placement
    end
  end
end
