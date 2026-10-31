# frozen_string_literal: true

require_relative "base"

module Haskimail
  module Resources
    # Templates: https://haskimail.ru/developer/api/templates-api
    # Sending by template lives in {Emails#deliver_with_template}.
    class Templates < Base
      # GET /templates
      # @return [ApiObject] TotalCount, Templates[]
      def list(count: nil, offset: nil)
        check_paging!(count, offset)
        object(api_get("/templates", query({ count: count, offset: offset }, PAGING)))
      end

      # Iterates over all templates, requesting pages lazily.
      # @return [Paginator]
      def each(page_size: 500, &block)
        paginator = paginate("Templates", page_size: page_size) do |count, offset|
          api_get("/templates", { "count" => count, "offset" => offset })
        end
        run(paginator, block)
      end

      # GET /templates/{templateIdOrAlias}
      # @param id_or_alias [Integer, String]
      def get(id_or_alias)
        object(api_get(path("/templates/%s", id_or_alias)))
      end

      # POST /templates
      #   client.templates.create(name: "order-created", subject: "Заказ {{order}}",
      #                           html_body: "<p>{{name}}</p>", text_body: "{{name}}")
      def create(params = nil, **fields)
        payload = Util.to_api(merge_params(params, fields))
        raise ValidationError, "name is required" if Util.blank?(payload["Name"])

        object(api_post("/templates", payload))
      end

      # PUT /templates/{templateIdOrAlias}
      #
      # The API overwrites all four fields and blanks any that are omitted,
      # so all four are required here to prevent accidental data loss.
      # Pass "" explicitly to clear a field.
      def update(id_or_alias, name:, subject:, html_body:, text_body:)
        payload = { "Name" => name, "Subject" => subject, "HtmlBody" => html_body, "TextBody" => text_body }
        payload.each do |field, value|
          raise ValidationError, "#{field} must be a String (use \"\" to clear it)" unless value.is_a?(String)
        end
        raise ValidationError, "name must not be blank" if Util.blank?(name)

        object(api_put(path("/templates/%s", id_or_alias), payload))
      end

      # DELETE /templates/{templateIdOrAlias}
      def delete(id_or_alias)
        object(api_delete(path("/templates/%s", id_or_alias)))
      end

      # POST /templates/validate — renders a template without saving or sending.
      # Answers 200 even if the template has errors: check `all_content_is_valid`.
      #
      #   result = client.templates.validate(subject: "Заказ {{order}}",
      #                                      test_render_model: { "{{order}}" => "1042" })
      #   result.all_content_is_valid # => true
      def validate(params = nil, **fields)
        payload = Util.to_api(merge_params(params, fields))
        unless %w[Subject HtmlBody TextBody].any? { |key| payload.key?(key) }
          raise ValidationError, "At least one of subject, html_body, text_body is required"
        end

        object(api_post("/templates/validate", payload, idempotent: true))
      end
    end

    # Templates as seen by the account token; adds moving between servers.
    class AccountTemplates < Templates
      # POST /templates — with the account token `associated_server_id:` is
      # required (the server the template is created on).
      def create(params = nil, **fields)
        merged = merge_params(params, fields)
        unless Util.to_api(merged).key?("AssociatedServerId")
          raise ValidationError, "associated_server_id is required with the account token"
        end

        super(merged)
      end

      # PUT /templates/push — MOVES (not copies) every template of one server
      # to another. Use `perform_changes: false` for a dry run.
      #
      # @param perform_changes [Boolean] required on purpose: no default for a destructive call
      def push(source_server_id:, destination_server_id:, perform_changes:)
        raise ValidationError, "perform_changes must be true or false" unless [true, false].include?(perform_changes)

        payload = {
          "SourceServerID" => source_server_id,
          "DestinationServerID" => destination_server_id,
          "PerformChanges" => perform_changes
        }
        object(api_put("/templates/push", payload, idempotent: false))
      end
    end
  end
end
