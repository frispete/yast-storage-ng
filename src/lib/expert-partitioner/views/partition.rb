
require "yast"
require "storage"
require "storage/storage-manager"
require "storage/extensions"
require "expert-partitioner/views/view"

Yast.import "UI"
Yast.import "HTML"

include Yast::I18n


module ExpertPartitioner

  class PartitionView < View

    def initialize(partition)
      @partition = partition
    end

    def create

      tmp = [ "Name: #{@partition.name}",
              "Size: #{::Storage::byte_to_humanstring(1024 * @partition.size_k, false, 2, false)}" ]

      tmp << "Device Path: #{@partition.udev_path}"

      @partition.udev_ids.each_with_index do |udev_id, i|
        tmp << "Device ID #{i + 1}: #{udev_id}"
      end

      contents = Yast::HTML.List(tmp)

      return RichText(Id(:text), Opt(:hstretch, :vstretch), contents)

    end

  end

end
