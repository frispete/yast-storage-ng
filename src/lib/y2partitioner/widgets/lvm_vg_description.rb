# Copyright (c) [2017-2019] SUSE LLC
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

require "y2partitioner/widgets/device_description"
require "y2partitioner/widgets/description_section/lvm_vg_device"
require "y2partitioner/widgets/description_section/lvm_vg"

module Y2Partitioner
  module Widgets
    # Description for a LVM VG
    class LvmVgDescription < DeviceDescription
      private

      # @see DiskDeviceDescription#sections
      def sections
        [
          DescriptionSection::LvmVgDevice.new(device),
          DescriptionSection::LvmVg.new(device)
        ]
      end
    end
  end
end
