#!/usr/bin/env rspec
# encoding: utf-8

# Copyright (c) [2016] SUSE LLC
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

require_relative "../spec_helper"
require "y2storage"

describe Y2Storage::Proposal::SpaceMaker do
  describe "#make_space" do
    using Y2Storage::Refinements::SizeCasts

    # Partition from fake_devicegraph, fetched by name
    def probed_partition(name)
      fake_devicegraph.partitions.detect { |p| p.name == name }
    end

    before do
      fake_scenario(scenario)
      allow(analyzer).to receive(:windows_partitions).and_return windows_partitions
    end

    let(:settings) do
      settings = Y2Storage::ProposalSettings.new
      settings.candidate_devices = ["/dev/sda"]
      settings.root_device = "/dev/sda"
      settings
    end
    let(:volumes) { vols_list(vol1) }
    let(:analyzer) { Y2Storage::DiskAnalyzer.new(fake_devicegraph) }
    let(:lvm_helper) { Y2Storage::Proposal::LvmHelper.new(Y2Storage::PlannedVolumesList.new) }
    let(:windows_partitions) { [] }

    subject(:maker) { described_class.new(fake_devicegraph, analyzer, lvm_helper, settings) }

    context "if the only disk is not big enough" do
      let(:scenario) { "empty_hard_disk_mbr_50GiB" }
      let(:vol1) { planned_vol(mount_point: "/1", type: :ext4, desired: 60.GiB) }

      it "raises a NoDiskSpaceError exception" do
        expect { maker.provide_space(volumes) }
          .to raise_error Y2Storage::Proposal::NoDiskSpaceError
      end
    end

    context "if the only disk has no partition table" do
      let(:scenario) { "empty_hard_disk_50GiB" }
      let(:vol1) { planned_vol(mount_point: "/1", type: :ext4, desired: 40.GiB) }

      it "does not modify the disk" do
        result = maker.provide_space(volumes)
        disk = result[:devicegraph].disks.first
        expect(disk.partition_table).to be_nil
      end

      it "assumes a (future) GPT partition table" do
        gpt_size = 1.MiB
        # The final 16.5 KiB are reserved by GPT
        gpt_final_space = 16.5.KiB

        result = maker.provide_space(volumes)
        space = result[:space_distribution].spaces.first
        expect(space.disk_size).to eq(50.GiB - gpt_size - gpt_final_space)
      end
    end

    context "with one disk containing Windows and Linux partitions" do
      let(:scenario) { "windows-linux-multiboot-pc" }
      let(:vol1) { planned_vol(mount_point: "/1", type: :ext4, desired: 100.GiB) }
      let(:windows_partitions) { [analyzer_part("/dev/sda1")] }

      it "deletes linux partitions as needed" do
        result = maker.provide_space(volumes)
        expect(result[:devicegraph].partitions).to contain_exactly(
          an_object_having_attributes(filesystem_label: "windows", size: 250.GiB),
          an_object_having_attributes(filesystem_label: "swap", size: 2.GiB)
        )
      end

      it "stores the list of deleted partitions" do
        result = maker.provide_space(volumes)
        expect(result[:deleted_partitions]).to contain_exactly(
          an_object_having_attributes(filesystem_label: "root", size: 248.GiB - 1.MiB)
        )
      end

      it "suggests a distribution using the freed space" do
        result = maker.provide_space(volumes)
        distribution = result[:space_distribution]
        expect(distribution.spaces.size).to eq 1
        expect(distribution.spaces.first.volumes).to eq volumes
      end

      context "if deleting Linux is not enough" do
        let(:vol2) { planned_vol(mount_point: "/2", type: :ext4, desired: 200.GiB) }
        let(:volumes) { vols_list(vol1, vol2) }
        let(:resize_info) do
          instance_double("Y2Storage::ResizeInfo", resize_ok?: true, min_size: 100.GiB)
        end

        before do
          allow_any_instance_of(Y2Storage::Filesystems::BlkFilesystem).to receive(:detect_resize_info)
            .and_return(resize_info)
        end

        it "resizes Windows partitions to free additional needed space" do
          result = maker.provide_space(volumes)
          expect(result[:devicegraph].partitions).to contain_exactly(
            an_object_having_attributes(filesystem_label: "windows", size: 200.GiB - 1.MiB)
          )
        end
      end
    end

    context "with one disk containing a Windows partition and no Linux ones" do
      let(:scenario) { "windows-pc" }
      let(:resize_info) do
        instance_double("Y2Storage::ResizeInfo", resize_ok?: true, min_size: 730.GiB)
      end
      let(:windows_partitions) { [analyzer_part("/dev/sda1")] }

      before do
        allow_any_instance_of(Y2Storage::Filesystems::BlkFilesystem).to receive(:detect_resize_info)
          .and_return(resize_info)
      end

      context "with enough free space in the Windows partition" do
        let(:vol1) { planned_vol(mount_point: "/1", type: :ext4, desired: 40.GiB) }

        it "shrinks the Windows partition by the required size" do
          result = maker.provide_space(volumes)
          win_partition = Y2Storage::Partition.find_by_name(result[:devicegraph], "/dev/sda1")
          expect(win_partition.size).to eq 740.GiB
        end

        it "leaves other partitions untouched" do
          result = maker.provide_space(volumes)
          expect(result[:devicegraph].partitions).to contain_exactly(
            an_object_having_attributes(filesystem_label: "windows"),
            an_object_having_attributes(filesystem_label: "recovery", size: 20.GiB - 1.MiB)
          )
        end

        it "leaves empty the list of deleted partitions" do
          result = maker.provide_space(volumes)
          expect(result[:deleted_partitions]).to be_empty
        end

        it "suggests a distribution using the freed space" do
          result = maker.provide_space(volumes)
          distribution = result[:space_distribution]
          expect(distribution.spaces.size).to eq 1
          expect(distribution.spaces.first.volumes).to eq volumes
        end
      end

      context "with no enough free space in the Windows partition" do
        let(:vol1) { planned_vol(mount_point: "/1", type: :ext4, desired: 60.GiB) }

        it "shrinks the Windows partition as much as possible" do
          result = maker.provide_space(volumes)
          win_partition = Y2Storage::Partition.find_by_name(result[:devicegraph], "/dev/sda1")
          expect(win_partition.size).to eq 730.GiB
        end

        it "removes other partitions" do
          result = maker.provide_space(volumes)
          expect(result[:devicegraph].partitions).to contain_exactly(
            an_object_having_attributes(filesystem_label: "windows")
          )
        end

        it "stores the list of deleted partitions" do
          result = maker.provide_space(volumes)
          expect(result[:deleted_partitions]).to contain_exactly(
            an_object_having_attributes(filesystem_label: "recovery", size: 20.GiB - 1.MiB)
          )
        end

        it "suggests a distribution using the freed space" do
          result = maker.provide_space(volumes)
          distribution = result[:space_distribution]
          expect(distribution.spaces.size).to eq 1
          expect(distribution.spaces.first.volumes).to eq volumes
        end
      end
    end

    context "if there are two Windows partitions" do
      let(:scenario) { "double-windows-pc" }
      let(:resize_info) do
        instance_double("Y2Storage::ResizeInfo", resize_ok?: true, min_size: 50.GiB)
      end
      let(:windows_partitions) do
        [
          analyzer_part("/dev/sda1"),
          analyzer_part("/dev/sdb1")
        ]
      end
      let(:vol1) { planned_vol(mount_point: "/1", type: :ext4, desired: 20.GiB) }

      before do
        settings.candidate_devices = ["/dev/sda", "/dev/sdb"]
        allow_any_instance_of(Y2Storage::Filesystems::BlkFilesystem).to receive(:detect_resize_info)
          .and_return(resize_info)
      end

      it "shrinks first the less full Windows partition" do
        result = maker.provide_space(volumes)
        win2_partition = Y2Storage::Partition.find_by_name(result[:devicegraph], "/dev/sdb1")
        expect(win2_partition.size).to eq 160.GiB
      end

      it "leaves other partitions untouched if possible" do
        result = maker.provide_space(volumes)
        expect(result[:devicegraph].partitions).to contain_exactly(
          an_object_having_attributes(filesystem_label: "windows1", size: 80.GiB),
          an_object_having_attributes(filesystem_label: "recovery1", size: 20.GiB - 1.MiB),
          an_object_having_attributes(filesystem_label: "windows2"),
          an_object_having_attributes(filesystem_label: "recovery2", size: 20.GiB - 1.MiB)
        )
      end
    end

    context "when forced to delete partitions" do
      let(:scenario) { "multi-linux-pc" }

      it "deletes the last partitions of the disk until reaching the goal" do
        vol = planned_vol(mount_point: "/1", type: :ext4, desired: 700.GiB)
        volumes = vols_list(vol)

        result = maker.provide_space(volumes)
        expect(result[:deleted_partitions]).to contain_exactly(
          an_object_having_attributes(name: "/dev/sda4", size: 900.GiB - 1.MiB),
          an_object_having_attributes(name: "/dev/sda5", size: 300.GiB),
          an_object_having_attributes(name: "/dev/sda6", size: 600.GiB - 3.MiB)
        )
        expect(result[:devicegraph].partitions).to contain_exactly(
          an_object_having_attributes(name: "/dev/sda1", size: 4.GiB),
          an_object_having_attributes(name: "/dev/sda2", size: 60.GiB),
          an_object_having_attributes(name: "/dev/sda3", size: 60.GiB)
        )
      end

      it "doesn't delete partitions marked to be reused" do
        vol1 = planned_vol(mount_point: "/1", type: :ext4, desired: 100.GiB)
        vol2 = planned_vol(mount_point: "/2", reuse: "/dev/sda6")
        volumes = vols_list(vol1, vol2)
        sda6 = probed_partition("/dev/sda6")

        result = maker.provide_space(volumes)
        expect(result[:devicegraph].partitions.map(&:sid)).to include sda6.sid
        expect(result[:deleted_partitions].map(&:sid)).to_not include sda6.sid
      end

      it "raises a NoDiskSpaceError exception if deleting is not enough" do
        vol1 = planned_vol(mount_point: "/1", type: :ext4, desired: 980.GiB)
        vol2 = planned_vol(mount_point: "/2", reuse: "/dev/sda2")
        volumes = vols_list(vol1, vol2)

        expect { maker.provide_space(volumes) }.to raise_error Y2Storage::Proposal::NoDiskSpaceError
      end

      it "deletes extended partitions when deleting all its logical children" do
        volumes = vols_list(
          planned_vol(mount_point: "/1", type: :ext4, desired: 800.GiB),
          planned_vol(mount_point: "/2", reuse: "/dev/sda1"),
          planned_vol(mount_point: "/2", reuse: "/dev/sda2"),
          planned_vol(mount_point: "/2", reuse: "/dev/sda3")
        )

        result = maker.provide_space(volumes)
        expect(result[:devicegraph].partitions).to contain_exactly(
          an_object_having_attributes(name: "/dev/sda1", size: 4.GiB),
          an_object_having_attributes(name: "/dev/sda2", size: 60.GiB),
          an_object_having_attributes(name: "/dev/sda3", size: 60.GiB)
        )
        expect(result[:deleted_partitions]).to contain_exactly(
          an_object_having_attributes(name: "/dev/sda4"),
          an_object_having_attributes(name: "/dev/sda5"),
          an_object_having_attributes(name: "/dev/sda6")
        )
      end

      # In the past, SpaceMaker used to delete the extended partition sda4
      # leaving sda6 alive. This test ensures the bug does not re-appear
      it "does not delete the extended partition if some logical one is to be reused" do
        volumes = vols_list(
          planned_vol(mount_point: "/1", type: :ext4, desired: 400.GiB),
          planned_vol(mount_point: "/2", reuse: "/dev/sda1"),
          planned_vol(mount_point: "/3", reuse: "/dev/sda2"),
          planned_vol(mount_point: "/4", reuse: "/dev/sda3"),
          planned_vol(mount_point: "/5", reuse: "/dev/sda6")
        )

        expect { maker.provide_space(volumes) }.to raise_error Y2Storage::Proposal::NoDiskSpaceError
      end
    end

    context "when some volumes must be reused" do
      let(:scenario) { "multi-linux-pc" }
      let(:volumes) do
        vols_list(
          planned_vol(mount_point: "/1", type: :ext4, desired: 60.GiB),
          planned_vol(mount_point: "/2", type: :ext4, desired: 300.GiB),
          planned_vol(mount_point: "/3", reuse: "/dev/sda6"),
          planned_vol(mount_point: "/4", reuse: "/dev/sda2")
        )
      end

      it "ignores reused partitions in the suggested distribution" do
        result = maker.provide_space(volumes)
        distribution = result[:space_distribution]
        dist_volumes = distribution.spaces.map { |s| s.volumes.to_a }.flatten
        expect(dist_volumes).to_not include an_object_having_attributes(mount_point: "/3")
        expect(dist_volumes).to_not include an_object_having_attributes(mount_point: "/4")
      end

      it "only makes space for non reused volumes" do
        result = maker.provide_space(volumes)
        devgraph = result[:devicegraph]
        freed_space = devgraph.free_disk_spaces.map(&:disk_size).reduce(Y2Storage::DiskSize.zero, :+)
        # Extra MiB for rounding issues
        expect(freed_space).to eq(360.GiB + 1.MiB)
      end
    end

    context "when some volumes have disk restrictions" do
      let(:scenario) { "mixed_disks" }
      let(:resize_info) do
        instance_double("Y2Storage::ResizeInfo", resize_ok?: true, min_size: 50.GiB)
      end
      let(:windows_partitions) { [analyzer_part("/dev/sda1")] }
      let(:vol1) { planned_vol(mount_point: "/1", type: :ext4, disk: "/dev/sda") }
      let(:vol2) { planned_vol(mount_point: "/2", type: :ext4, disk: "/dev/sda") }
      let(:vol3) { planned_vol(mount_point: "/3", type: :ext4) }
      let(:volumes) { vols_list(vol1, vol2, vol3) }

      before do
        settings.candidate_devices = ["/dev/sda", "/dev/sdb"]
        allow_any_instance_of(Y2Storage::Filesystems::BlkFilesystem).to receive(:detect_resize_info)
          .and_return(resize_info)
      end

      context "if the choosen disk has no enough space" do
        before do
          vol1.desired = 101.GiB
          vol2.desired = 100.GiB
          vol3.desired = 1.GiB
        end

        it "raises an exception even if there is enough space in other disks" do
          expect { maker.provide_space(volumes) }.to raise_error Y2Storage::Proposal::Error
        end
      end

      context "if several disks can allocate the volumes" do
        before do
          vol1.desired = 60.GiB
          vol2.desired = 60.GiB
          vol3.desired = 1.GiB
        end

        it "ensures disk restrictions are honored" do
          result = maker.provide_space(volumes)
          distribution = result[:space_distribution]
          sda_space = distribution.spaces.detect { |i| i.disk_name == "/dev/sda" }
          # Without disk restrictions, it would have deleted linux partitions at /dev/sdb and
          # allocated the volumes there
          expect(sda_space.volumes).to include vol1
          expect(sda_space.volumes).to include vol2
        end

        it "applies the usual criteria to allocate non-restricted volumes" do
          result = maker.provide_space(volumes)
          distribution = result[:space_distribution]
          sdb_space = distribution.spaces.detect { |i| i.disk_name == "/dev/sdb" }
          # Default action: delete linux partitions at /dev/sdb and allocate volumes there
          expect(sdb_space.volumes).to include vol3
        end
      end
    end

    context "when deleting a partition which belongs to a LVM" do
      let(:scenario) { "lvm-two-vgs" }
      let(:windows_partitions) { [analyzer_part("/dev/sda1")] }
      let(:volumes) { vols_list(planned_vol(mount_point: "/1", type: :ext4, desired: 2.GiB)) }

      it "deletes also other partitions of the same volume group" do
        result = maker.provide_space(volumes)
        partitions = result[:devicegraph].partitions

        expect(partitions.map(&:sid)).to_not include probed_partition("/dev/sda9").sid
        expect(partitions.map(&:sid)).to_not include probed_partition("/dev/sda5").sid
      end

      it "deletes the volume group itself" do
        result = maker.provide_space(volumes)

        expect(result[:devicegraph].lvm_vgs.map(&:vg_name)).to_not include "vg1"
      end

      it "does not affect partitions from other volume groups" do
        result = maker.provide_space(volumes)
        devicegraph = result[:devicegraph]

        expect(devicegraph.partitions.map(&:name)).to include "/dev/sda7"
        expect(devicegraph.lvm_vgs.map(&:vg_name)).to include "vg0"
      end
    end

    context "when a LVM VG is going to be reused" do
      let(:scenario) { "lvm-two-vgs" }
      let(:windows_partitions) { [analyzer_part("/dev/sda1")] }
      let(:resize_info) do
        instance_double("Y2Storage::ResizeInfo", resize_ok?: true, min_size: 10.GiB)
      end

      before do
        # We are reusing vg1
        expect(lvm_helper).to receive(:partitions_in_vg).and_return ["/dev/sda5", "/dev/sda9"]
        # At some point, we can try to resize Windows
        allow_any_instance_of(Y2Storage::Filesystems::BlkFilesystem).to receive(:detect_resize_info)
          .and_return(resize_info)
      end

      it "does not delete partitions belonging to the reused VG" do
        volumes = vols_list(planned_vol(mount_point: "/1", type: :ext4, desired: 2.GiB))
        result = maker.provide_space(volumes)
        partitions = result[:devicegraph].partitions

        # sda5 and sda9 belong to vg1
        expect(partitions.map(&:sid)).to include probed_partition("/dev/sda9").sid
        expect(partitions.map(&:sid)).to include probed_partition("/dev/sda5").sid
        # sda8 is deleted instead of sda9
        expect(partitions.map(&:sid)).to_not include probed_partition("/dev/sda8").sid
      end

      it "does nothing special about partitions from other VGs" do
        volumes = vols_list(planned_vol(mount_point: "/1", type: :ext4, desired: 6.GiB))
        result = maker.provide_space(volumes)
        partitions = result[:devicegraph].partitions

        # sda7 belongs to vg0
        expect(partitions.map(&:sid)).to_not include probed_partition("/dev/sda7").sid
      end

      it "raises NoDiskSpaceError if it cannot find space respecting the VG" do
        volumes = vols_list(
          # This exhausts the primary partitions
          planned_vol(mount_point: "/1", type: :ext4, desired: 30.GiB),
          # This implies deleting linux partitions out of vg1
          planned_vol(mount_point: "/2", type: :ext4, desired: 14.GiB),
          # So this one, as small as it is, would affect vg1
          planned_vol(mount_point: "/2", type: :ext4, desired: 10.MiB)
        )
        expect { maker.provide_space(volumes) }
          .to raise_error Y2Storage::Proposal::NoDiskSpaceError
      end
    end
  end
end
