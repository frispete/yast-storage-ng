require "yast"
require "cwm/tabs"
require "y2partitioner/ui_state"

Yast.import "UI"

module Y2Partitioner
  module Widgets
    # Mixin for the different Tab subclasses to interact with {UIState}
    module TabsWithState
      # Overrides default behavior of tabs to register the status of the current
      # page and the set the new one in {UIState} before doing the real switch
      def switch_page(page)
        state = UIState.instance

        state.save_extra_info

        target = (page == default_page) ? nil : page.label
        state.switch_to_tab(target)

        super
      end

      # Ensures tabs are properly initialized after a redraw according to
      # {UIState}.
      def initial_page
        find_initial_page || super
      end

      def find_initial_page
        @pages.find { |page| page.label == UIState.instance.active_tab }
      end
    end

    # Specialized class of the Tabs widget implementing partitioner-specific
    # behavior, like interacting with {UIState} to provide a consistent user
    # experience.
    class Tabs < CWM::Tabs
      # Follow the same (very surprising) behavior of CWM::Tabs of redefining
      # self.new to call {DumbTabPager}.new or {PushButtonTabPager}.new.
      def self.new(*args)
        if Yast::UI.HasSpecialWidget(:DumbTab)
          DumbTabPager.new(*args)
        else
          PushButtonTabPager.new(*args)
        end
      end
    end

    # @see Tabs
    class DumbTabPager < CWM::DumbTabPager
      alias_method :default_page, :initial_page
      include TabsWithState
    end

    # @see Tabs
    class PushButtonTabPager < CWM::PushButtonTabPager
      alias_method :default_page, :initial_page
      include TabsWithState
    end
  end
end
