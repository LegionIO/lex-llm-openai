# frozen_string_literal: true

require 'legion/settings/helper'
require 'legion/logging'

# The LegionIO daemon provides the actor runtime (Every) and the extension
# helper (Lex). Specs run against the lex gems only, so stub the minimal
# surface the actor files need to load. Each stub is a no-op when the real
# constant already exists.
module Legion
  module Extensions
    module Actors
      unless const_defined?(:Every, false)
        # Test stand-in for Legion::Extensions::Actors::Every. Instances are
        # driven directly via #manual / #shutdown in specs; no timer is
        # started.
        class Every
          def initialize(**)
            # Intentionally timer-free.
          end
        end
      end
    end

    module Helpers
      unless const_defined?(:Lex, false)
        # Functional stand-in for the LegionIO `Legion::Extensions::Helpers::Lex`
        # helper. Provides the REAL settings/log/handle_exception the shared
        # Discovery::Pipeline (mixed into the provider runner module) relies
        # on, without loading the full LegionIO helper stack: `settings` comes
        # from the real Legion::Settings::Helper (legion-settings 1.4.2: the
        # nested path Legion::Settings[:extensions][:llm][:openai]) so specs
        # exercise production settings resolution and drive discovery + D14
        # health display writes through the genuine settings tree, and
        # Legion::Logging::Helper provides `log` + `handle_exception` — the
        # pipeline calls both from every tick's rescue path.
        #
        # The self-extend hook mirrors the real Lex so module-level runners
        # get settings/log/handle_exception on the module.
        module Lex
          include Legion::Logging::Helper
          include Legion::Settings::Helper

          def self.included(base)
            base.extend(base) if base.instance_of?(Module) && !base.instance_of?(Class)
          end
        end
      end
    end
  end
end
