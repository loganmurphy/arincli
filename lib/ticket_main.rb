# Copyright (C) 2011,2012 American Registry for Internet Numbers
#
# Permission to use, copy, modify, and/or distribute this software for any
# purpose with or without fee is hereby granted, provided that the above
# copyright notice and this permission notice appear in all copies.
#
# THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
# WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
# MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
# ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
# WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
# ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF OR
# IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.


require 'optparse'
require 'rexml/document'
require 'base_opts'
require 'config'
require 'constants'
require 'reg_rws'
require 'ticket_reg'
require 'editor'
require 'data_tree'
require 'time'
require 'tempfile'
require 'uri'

module ARINr

  module Registration

    class TicketMain < ARINr::BaseOpts

      def initialize args, config = nil

        if config
          @config = config
        else
          @config = ARINr::Config.new( ARINr::Config::formulate_app_data_dir() )
        end

        @opts = OptionParser.new do |opts|

          opts.banner = "Usage: ticket [options] [TICKET_NO]"

          opts.separator ""
          opts.separator "Actions:"

          opts.on( "-c", "--check",
                   "Checks to see if a given ticket or all tickets have been updated." ) do |check|
            @config.options.check_ticket = true
          end

          opts.on( "-u", "--update",
                   "Downloads a given ticket if updated or all updated tickets." ) do |check|
            @config.options.update_ticket = true
          end

          opts.on( "--force-update",
                   "Forces a download of a given ticket or all tickets." ) do |check|
            @config.options.update_ticket = true
            @config.options.force_update = true
          end

          opts.on( "-s", "--show",
                   "Shows information on a given ticket or summary of all tickets." ) do |check|
            @config.options.show_ticket = true
          end

          opts.separator ""
          opts.separator "Communications Options:"

          opts.on( "-U", "--url URL",
                   "The base URL of the Registration RESTful Web Service." ) do |url|
            @config.config[ "registration" ][ "url" ] = url
          end

          opts.on( "-A", "--apikey APIKEY",
                   "The API KEY to use with the RESTful Web Service." ) do |apikey|
            @config.config[ "registration" ][ "apikey" ] = apikey.to_s.upcase
          end

        end

        add_base_opts( @opts, @config )

        begin
          @opts.parse!( args )
        rescue OptionParser::InvalidArgument => e
          puts e.message
          puts "use -h for help"
          exit
        end
        @config.options.argv = args

      end

      def run

        if( @config.options.help )
          help()
          return
        end

        @config.logger.mesg( ARINr::VERSION )
        @config.setup_workspace
        @store_mgr = ARINr::Registration::TicketStorageManager.new @config

        if @config.options.argv[ 0 ] && @config.options.argv[ 0 ] =~ ARINr::DATA_TREE_ADDR_REGEX
          tree = @config.load_as_yaml( ARINr::TICKET_LASTTREE_YAML )
          # this is a short cut that basically says go consult the ticket tree db
          # it is an optimization to stop from saving the ticket tree db as the last ticket/ticket lis
          if tree != nil && tree.roots != nil && tree.roots[ 0 ].rest_ref == ARINr::TICKET_TREE_YAML
            tree = get_tree_mgr.get_ticket_tree
          end
          v = tree.find_handle @config.options.argv[ 0 ]
          @config.options.argv[ 0 ] = v if v
        end

        if @config.options.check_ticket
          @config.logger.run_pager
          check_tickets()
        elsif @config.options.update_ticket
          update_tickets()
        elsif @config.options.show_ticket
          @config.logger.run_pager
          show_tickets()
        else
          @config.logger.run_pager
          show_tickets()
        end

        @config.logger.end_run
        @tree_mgr.save

      end

      def get_tree_mgr
        if @tree_mgr == nil
          @tree_mgr = ARINr::Registration::TicketTreeManager.new @config
          @tree_mgr.load
        end
        @tree_mgr
      end

      def help

        puts ARINr::VERSION
        puts ARINr::COPYRIGHT
        puts <<HELP_SUMMARY

This program uses ARIN's Reg-RWS RESTful API to query ARIN's Registration database.
The general usage is "ticket TICKET_NO" where TICKET_NO is the identifier of the ticket
to be acted upon.

HELP_SUMMARY
        puts @opts.help
        exit

      end

      def check_tickets

        last_tree = ARINr::DataTree.new

        reg = ARINr::Registration::RegistrationService.new @config, ARINr::TICKET_TX_PREFIX
        element = reg.get_ticket_summary( @config.options.argv[ 0 ] )
        if ! element
          @config.logger.mesg( "Unable to get ticket summary information." )
        elsif element.name == "collection"
          element.elements.each( "ticket" ) do |ticket|
            check_ticket( ticket, last_tree )
          end
        elsif element.name == "ticket"
          check_ticket( element, last_tree )
        else
          @config.logger.mesg( "Unimplemented ticket check!" )
        end

        if !last_tree.empty?
          last_tree.to_terse_log( @config.logger, true )
          @config.save_as_yaml( ARINr::TICKET_LASTTREE_YAML, last_tree )
        else
          @config.logger.mesg( "No tickets have been updated." )
        end
        return last_tree
      end

      def check_ticket( element, last_tree )
        ticket = ARINr::Registration.element_to_ticket element
        if get_tree_mgr.out_of_date?( ticket.ticket_no, ticket.updated_date )
          s = format( "%-20s %-15s %-15s", ticket.ticket_no, ticket.ticket_type, ticket.ticket_status )
          ticket_node = ARINr::DataNode.new( s, ticket.ticket_no )
          last_tree.add_root( ticket_node )
        end
      end

      def update_tickets
        updated = check_tickets
        reg = ARINr::Registration::RegistrationService.new @config, ARINr::TICKET_TX_PREFIX
        updated.roots.each do |ticket|
          ticket_no = ticket.handle
          @config.logger.mesg( "Getting ticket #{ticket_no}" )
          ticket_uri = reg.ticket_uri ticket_no
          element = reg.get_data ticket_uri
          new_ticket = ARINr::Registration.element_to_ticket element
          new_ticket_file = @store_mgr.put_ticket new_ticket
          new_ticket_node = get_tree_mgr.put_ticket( new_ticket, new_ticket_file, ticket_uri )
          new_ticket.messages.each do |message|
            @config.logger.mesg( "Getting message #{ticket_no} : #{message.id}" )
            message_uri = reg.ticket_message_uri( ticket_no, message.id )
            message_element = reg.get_data message_uri
            message_xml = ARINr::Registration::element_to_ticket_message message_element
            message_file = @store_mgr.put_ticket_message( new_ticket, message_xml )
            message_node =
                    get_tree_mgr.put_ticket_message(
                            new_ticket_node, message_xml, message_file, message_uri )
            message.attachments.each do |attachment|
              @config.logger.mesg( "Getting attachment #{ticket_no} : #{message.id} : #{attachment.id}" )
              attachment_uri = reg.ticket_attachment_uri( ticket_no, message.id, attachment.id )
              attachment_file = @store_mgr.prepare_file_attachment( new_ticket, message, attachment.id )
              f = File.open( attachment_file, "w" )
              reg.get_data_as_stream( attachment_uri, f )
              f.close
              get_tree_mgr.put_ticket_attachment(
                      new_ticket_node, message_node, attachment, attachment_file, attachment_uri)
            end
          end
        end
      end

      def show_tickets
        mgr = ARINr::Registration::TicketStorageManager.new @config
        if @config.options.argv[ 0 ]
          ticket = mgr.get_ticket_summary @config.options.argv[ 0 ]
          if ! ticket
            @config.logger.mesg( "Ticket " + @config.options.argv[ 0 ] + " cannot be found." )
            return nil
          end
          tree = ARINr::DataTree.new
          tree.add_root( get_ticket_node( mgr, ticket ) )
          if( tree.to_normal_log( @config.logger, true ) )
            @config.save_as_yaml( ARINT_TICKETS, tree )
          end
          @config.logger.start_data_item
          @config.logger.terse( "Ticket Number", ticket.ticket_no )
          @config.logger.terse( "Status", ticket.ticket_status )
          @config.logger.terse( "Resolution", ticket.ticket_resolution ) if ticket.ticket_resolution
          @config.logger.datum( "Type", ticket.ticket_type )
          @config.logger.terse( "Created", Time.parse( ticket.created_date ).rfc2822 ) if ticket.created_date
          @config.logger.datum( "Resolved", Time.parse( ticket.resolved_date ).rfc2822 ) if ticket.resolved_date
          @config.logger.datum( "Closed", Time.parse( ticket.closed_date ).rfc2822 ) if ticket.closed_date
          @config.logger.datum( "Updated", Time.parse( ticket.updated_date ).rfc2822 ) if ticket.updated_date
          message_entries = mgr.get_ticket_message_entries ticket
          @config.logger.extra( "Message Count", message_entries.size ) if message_entries
          @config.logger.end_data_item
          message_entries.each do |entry|
            message = mgr.get_ticket_message entry
            @config.logger.start_data_item
            log_banner "BEGIN MESSAGE"
            subject = "Subject:  " + message.subject if message.subject
            subject = "Subject:  ( NO SUBJECT GIVEN )" if !message.subject
            @config.logger.raw ARINr::DataAmount::TERSE_DATA, subject
            @config.logger.raw ARINr::DataAmount::TERSE_DATA, "Category: " + message.category if message.category
            @config.logger.raw ARINr::DataAmount::TERSE_DATA, ""
            message.text.each do |line|
              line = "" if !line
              auto_wrap = @config.config[ "output" ][ "auto_wrap" ]
              if auto_wrap && line.length > auto_wrap
                while line.length > auto_wrap
                  cutoff = line.rindex( " ", auto_wrap )
                  cutoff = auto_wrap if cutoff == 0
                  @config.logger.raw ARINr::DataAmount::TERSE_DATA, line[0..cutoff]
                  line = line[(cutoff+1)..-1]
                end
                @config.logger.raw ARINr::DataAmount::TERSE_DATA, line
              else
                @config.logger.raw ARINr::DataAmount::TERSE_DATA, line
              end
            end if message.text
            @config.logger.raw ARINr::DataAmount::TERSE_DATA, ""
            attachments = mgr.get_attachment_entries entry
            if attachments
              log_banner "ATTACHMENTS"
              attachments.each do |attachment|
                fn = URI.decode( File.basename( attachment ) )
                @config.logger.raw ARINr::DataAmount::TERSE_DATA, fn
              end
            end
            log_banner "END MESSAGE"
            @config.logger.end_data_item
          end if message_entries
        else
          tickets = mgr.get_ticket_summaries
          tree = ARINr::DataTree.new
          tickets.each do |ticket|
            root = get_ticket_node mgr, ticket
            tree.add_root( root )
          end
          if tree.empty?
            @config.logger.mesg( "No tickets found." )
          else
            tree.to_terse_log( @config.logger, true )
            @config.save_as_yaml( ARINT_TICKETS, tree )
          end
        end
      end

      def log_banner banner, fill_char = "-"
        s = fill_char + fill_char + " " + banner + " "
        (s.length..80).each {|x| s << fill_char}
        @config.logger.raw ARINr::DataAmount::TERSE_DATA, s
      end

      def get_ticket_node mgr, ticket
        s = format( "%s (%s, %s)",ticket.ticket_no, ticket.ticket_type, ticket.ticket_status )
        root = ARINr::DataNode.new( s, ticket.ticket_no )
        message_entries = mgr.get_ticket_message_entries ticket
        message_entries.each do |entry|
          message = mgr.get_ticket_message entry
          subject = message.subject ? message.subject : "( NO SUBJECT GIVEN )"
          message_node = ARINr::DataNode.new( subject )
          root.add_child( message_node )
          attachments = mgr.get_attachment_entries entry
          attachments.each do |attachment|
            fn = URI.decode( File.basename( attachment ) )
            attachment_node = ARINr::DataNode.new( fn, attachment )
            message_node.add_child( attachment_node )
          end if attachments
        end if message_entries
        return root
      end

    end

  end

end
