module RedmineElasticsearch
	module SerializesAttachments
		def self.included base
			base.attribute :attachments
		end

		def attachments
			object.attachments.map do |attachment|
				AttachmentSerializer.new(attachment, scope: scope, root: false, event: object)
			end
		end
	end
end