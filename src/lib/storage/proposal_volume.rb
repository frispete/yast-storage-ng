#!/usr/bin/env ruby
#
# encoding: utf-8

# Copyright (c) [2015] SUSE LLC
#
# All Rights Reserved.
#
# This program is free software; you can redistribute it and/or modify it
# under the terms of version 2 of the GNU General Public License as published
# by the Free Software Foundation.
#
# This program is distributed in the hope that it will be useful, but WITHOUT
# ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
# FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
# more details.
#
# You should have received a copy of the GNU General Public License along
# with this program; if not, contact SUSE LLC.
#
# To contact SUSE LLC about this file by physical or electronic mail, you may
# find current contact information at www.suse.com.

require "yast"
require "pp"

module Yast
  module Storage
    # Class to represent a planned volume (partition or logical volume) and
    # its constraints
    #
    class ProposalVolume
      attr_accessor :mount_point, :filesystem_type
      attr_accessor :size, :min_size, :max_size, :desired_size
      attr_accessor :can_live_on_logical_volume, :logical_volume_name

      def initialize(mount_point, filesystem_type = nil)
        @mount_point = mount_point
        @filesystem_type = filesystem_type
        @size         = DiskSize.zero
        @min_size     = DiskSize.zero
        @max_size     = DiskSize.unlimited
        @desired_size = DiskSize.unlimited
        @can_live_on_logical_volume = false
        @logical_volume_name = nil

        return unless @mount_point.start_with?("/")
        return if @mount_point.start_with?("/boot")

        @can_live_on_logical_volume = true
        if @mount_point == "/"
          @logical_volume_name = "root"
        else
          @logical_volume_name = @mount_point.sub(%r{^/}, "")
        end
      end
    end
  end
end
