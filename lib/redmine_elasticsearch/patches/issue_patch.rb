module RedmineElasticsearch
  module Patches
		module IssuePatch
			def set_watcher(user, watching=true)
				self.async_update_index if self.respond_to? :async_update_index
				super(user, watching)
			end
		end
  end
end