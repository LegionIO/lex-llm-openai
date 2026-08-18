# frozen_string_literal: true

require 'legion/settings/helper'

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
        # Test stand-in for Legion::Extensions::Helpers::Lex. Delegates
        # #settings to the real Legion::Settings::Helper so specs exercise
        # the production settings resolution (legion-settings 1.4.2: the
        # nested path Legion::Settings[:extensions][:llm][:openai]) rather
        # than an isolated fake hash.
        module Lex
          include Legion::Settings::Helper
        end
      end
    end
  end
end
