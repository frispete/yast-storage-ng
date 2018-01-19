#!/usr/bin/env rspec
# encoding: utf-8

# Copyright (c) [2017] SUSE LLC
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

require_relative "../test_helper"

require "yast"
require "cwm/rspec"
require "y2storage"
require "y2partitioner/dialogs/partition_resize"

describe Y2Partitioner::Dialogs::PartitionResize do
  using Y2Storage::Refinements::SizeCasts

  before do
    devicegraph_stub(scenario)
    allow(partition).to receive(:detect_resize_info).and_return resize_info
  end

  let(:current_graph) { Y2Partitioner::DeviceGraphs.instance.current }
  let(:scenario) { "mixed_disks" }

  # Creates a new partition
  let(:partition) do
    sdc = Y2Storage::Disk.find_by_name(current_graph, "/dev/sdc")
    if sdc
      sdc.partition_table.create_partition("/dev/sdc1", Y2Storage::Region.create(2048, 1048576, 512),
        Y2Storage::PartitionType::PRIMARY)
    else
      # DASD case, just take the first partition. That should be enough for
      # these tests
      current_graph.partitions.first
    end
  end

  let(:resize_info) do
    instance_double(Y2Storage::ResizeInfo,
      resize_ok?: true,
      min_size:   10.MiB,
      max_size:   100.GiB)
  end

  subject { described_class.new(partition) }

  include_examples "CWM::Dialog"

  describe "#contents" do
    def find_label(contents, text)
      contents.nested_find do |widget|
        widget.respond_to?(:value) &&
          widget.value == :Label &&
          widget.params.any? { |i| i.include?(text) }
      end
    end

    it "contains a widget for selecting the new size" do
      widget = subject.contents.nested_find do |w|
        w.is_a?(Y2Partitioner::Dialogs::PartitionResize::SizeSelector)
      end
      expect(widget).to_not be_nil
    end

    it "shows the current size" do
      label = find_label(subject.contents, "Current size")
      expect(label).to_not be_nil
    end

    context "when the partition does not exist on disk" do
      it "does not show the used size" do
        label = find_label(subject.contents, "Currently used")
        expect(label).to be_nil
      end
    end

    context "when the partition exists on disk" do
      let(:partition) { Y2Storage::Partition.find_by_name(current_graph, "/dev/sda2") }

      context "and it is not formatted" do
        before do
          allow(partition).to receive(:filesystem).and_return(nil)
        end

        it "does not show the used size" do
          label = find_label(subject.contents, "Currently used")
          expect(label).to be_nil
        end
      end

      context "and it is a swap partition" do
        before do
          allow(partition).to receive(:id).and_return(Y2Storage::PartitionId::SWAP)
        end

        it "does not show the used size" do
          label = find_label(subject.contents, "Currently used")
          expect(label).to be_nil
        end
      end

      context "and it is formatted and it is not swap" do
        before do
          allow(partition).to receive(:filesystem).and_return(filesystem)
        end

        let(:ext3) { Y2Storage::Filesystems::Type::EXT3 }
        let(:filesystem) { instance_double("Filesystem", detect_space_info: space_info, type: ext3) }
        let(:space_info) { instance_double(Y2Storage::SpaceInfo, used: 10.GiB) }

        it "shows the used size" do
          label = find_label(subject.contents, "Currently used")
          expect(label).to_not be_nil
        end
      end
    end
  end

  describe Y2Partitioner::Dialogs::PartitionResize::SizeSelector do
    subject(:widget) { described_class.new(partition) }

    before do
      allow(subject).to receive(:current_widget).and_return(current_widget)
      allow(partition).to receive(:detect_resize_info).and_return resize_info
    end

    let(:max_size_widget) { subject.widgets[0] }

    let(:min_size_widget) { subject.widgets[1] }

    let(:custom_size_widget) { subject.widgets[2] }

    let(:max_size) { 100.GiB }

    let(:min_size) { 10.MiB }

    let(:resize_info) do
      instance_double(Y2Storage::ResizeInfo,
        resize_ok?: true,
        min_size:   min_size,
        max_size:   max_size)
    end

    let(:current_widget) { max_size_widget }

    include_examples "CWM::AbstractWidget"

    describe "#store" do
      context "when max size is selected" do
        let(:current_widget) { max_size_widget }

        RSpec.shared_examples "max sizes" do
          context "and the max size causes an end-aligned partition" do
            let(:max_size) { aligned_max_size }

            it "updates the partition with the max size" do
              subject.store
              expect(partition.size).to eq max_size
              expect(partition.end_aligned?).to eq(true)
            end
          end

          context "and the max size causes a not end-aligned partition" do
            let(:max_size) { not_aligned_max_size }

            it "updates the partition with the max size" do
              subject.store
              expect(partition.size).to eq max_size
              expect(partition.end_aligned?).to eq(false)
            end
          end
        end

        context "when the partition table does not require end-alignment" do
          let(:scenario) { "mixed_disks" }

          let(:aligned_max_size) { 100.GiB }

          let(:not_aligned_max_size) { 100.GiB + 0.5.MiB }
          let(:adjusted_size) { 100.GiB }

          include_examples "max sizes"
        end

        context "when the partition table requires end-alignment (DASD)" do
          let(:scenario) { "dasd_50GiB.yml" }

          let(:aligned_max_size) { 204864.KiB }

          let(:not_aligned_max_size) { 200.MiB }
          let(:adjusted_size) { 204768.KiB }

          include_examples "max sizes"
        end
      end

      context "when min size is selected" do
        let(:current_widget) { min_size_widget }

        RSpec.shared_examples "min sizes" do
          context "and the min size causes an end-aligned partition" do
            let(:min_size) { aligned_min_size }

            it "updates the partition with the min size" do
              subject.store
              expect(partition.size).to eq min_size
              expect(partition.end_aligned?).to eq(true)
            end
          end

          context "and the min size causes a not end-aligned partition" do
            let(:min_size) { not_aligned_min_size }

            it "updates the partition with the min aligned size" do
              subject.store
              expect(partition.size).to eq adjusted_size
              expect(partition.end_aligned?).to eq(true)
              expect(partition.size).to be >= min_size
            end
          end
        end

        context "when the partition table does not require end-alignment" do
          let(:scenario) { "mixed_disks" }

          let(:aligned_min_size) { 10.MiB }

          let(:not_aligned_min_size) { 10.4.MiB }
          let(:adjusted_size) { 11.MiB }

          include_examples "min sizes"
        end

        context "when the partition table requires end-alignment (DASD)" do
          let(:scenario) { "dasd_50GiB.yml" }

          let(:aligned_min_size) { 24768.KiB }

          let(:not_aligned_min_size) { 12344.KiB }
          let(:adjusted_size) { 12384.KiB }

          include_examples "min sizes"
        end
      end

      context "when custom size is selected" do
        let(:current_widget) { custom_size_widget }

        before do
          allow(current_widget).to receive(:size).and_return(custom_size)
        end

        RSpec.shared_examples "custom sizes" do
          context "and the entered size causes an end-aligned partition" do
            let(:custom_size) { aligned_size }

            it "updates the partition with the entered size" do
              subject.store
              expect(partition.size).to eq aligned_size
              expect(partition.end_aligned?).to eq(true)
            end
          end

          context "and the entered size causes a not end-aligned partition" do
            let(:custom_size) { not_aligned_size }

            it "updates the partition with the closest valid aligned size" do
              subject.store
              expect(partition.size).to eq adjusted_size
              expect(partition.end_aligned?).to eq(true)
              expect(adjusted_size).to be <= max_size
              expect(adjusted_size).to be >= min_size
            end
          end
        end

        context "when the partition table does not require end-alignment" do
          let(:scenario) { "mixed_disks" }

          let(:aligned_size) { 50.GiB }

          let(:not_aligned_size) { 50.GiB + 0.5.MiB }
          let(:adjusted_size) { 50.GiB }

          include_examples "custom sizes"
        end

        context "when the partition table requires end-alignment (DASD)" do
          let(:scenario) { "dasd_50GiB.yml" }

          let(:aligned_size) { 204864.KiB }

          let(:not_aligned_size) { 200.MiB }
          let(:adjusted_size) { 204768.KiB }

          include_examples "custom sizes"
        end
      end
    end

    describe "#validate" do
      let(:current_widget) { custom_size_widget }

      before do
        allow(current_widget).to receive(:size).and_return(custom_size)
      end

      context "when the given value is less than the min possible size" do
        let(:custom_size) { 5.MiB }

        it "shows an error popup" do
          expect(Yast::Popup).to receive(:Error)
          subject.validate
        end

        it "returns false" do
          expect(subject.validate).to eq(false)
        end
      end

      context "when the given value is bigger than the max possible size" do
        let(:custom_size) { 101.GiB }

        it "shows an error popup" do
          expect(Yast::Popup).to receive(:Error)
          subject.validate
        end

        it "returns false" do
          expect(subject.validate).to eq(false)
        end
      end

      context "when the given value is not a valid size" do
        let(:custom_size) { nil }

        it "shows an error popup" do
          expect(Yast::Popup).to receive(:Error)
          subject.validate
        end

        it "returns false" do
          expect(subject.validate).to eq(false)
        end
      end

      context "when the given value is bigger than min and less than max" do
        let(:custom_size) { 10.GiB }

        it "returns true" do
          expect(subject.validate).to eq(true)
        end
      end
    end
  end

  describe Y2Partitioner::Dialogs::PartitionResize::FixedSizeWidget do
    subject(:widget) { described_class.new(1.GiB) }

    include_examples "CWM::AbstractWidget"
  end

  describe Y2Partitioner::Dialogs::PartitionResize::CustomSizeWidget do
    subject(:widget) { described_class.new(10.MiB, 100.GiB, 5.GiB) }

    include_examples "CWM::AbstractWidget"
  end
end
