require 'persisted_virtual_attributes.rb'

ActiveRecord::Base.send(:include, ActiveRecord::With::PersistedVirtualAttributes)