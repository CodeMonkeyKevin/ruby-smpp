require 'timeout'
require 'iconv'
require 'scanf'
require 'monitor'
require 'eventmachine'

module Smpp
  class InvalidStateException < Exception; end
    
  class Base < EventMachine::Connection
    include Smpp
    
    # :bound or :unbound
    attr_accessor :state
    # queries the state of the transmitter - is it bound?
    def unbound?
      @state == :unbound
    end
    def bound?
      @state == :bound
    end
    
    def Base.logger
      @@logger
    end

    def Base.logger=(logger)
      @@logger = logger
    end

    def logger
      @@logger
    end
    
    def initialize(config)
      @config = config
    end
    
    # invoked by EventMachine when connected
    def post_init
      # send Bind PDU if we are a binder (eg
      # Receiver/Transmitter/Transceiver
      send_bind unless defined?(am_server?) && am_server?

      # start timer that will periodically send enquire link PDUs
      start_enquire_link_timer(@config[:enquire_link_delay_secs]) if @config[:enquire_link_delay_secs]
    rescue Exception => ex
      logger.error "Error starting RX: #{ex.message} at #{ex.backtrace[0]}"
    end

    # sets up a periodic timer that will periodically enquire as to the
    # state of the connection
    # Note: to add in custom executable code (that only runs on an open
    # connection), derive from the appropriate Smpp class and overload the
    # method named: periodic_call_method
    def start_enquire_link_timer(delay_secs)
      logger.info "Starting enquire link timer (with #{delay_secs}s interval)"
      EventMachine::PeriodicTimer.new(delay_secs) do 
        if error?
          logger.warn "Link timer: Connection is in error state. Terminating loop."
          EventMachine::stop_event_loop
        elsif unbound?
          logger.warn "Link is unbound, waiting until next #{delay_secs} interval before querying again"
        else

          # if the user has defined a method to be called periodically, do
          # it now - and continue if it indicates to do so
          rval = defined?(periodic_call_method) ? periodic_call_method : true

          # only send an OK if this worked
          write_pdu Pdu::EnquireLink.new if rval 
        end
      end
    end

    # EventMachine::Connection#receive_data
    def receive_data(data)
      # parse incoming PDU
      pdu = read_pdu(data)
      
      # let subclass process it
      process_pdu(pdu) if pdu
    end
    
    # EventMachine::Connection#unbind
    def unbind
      logger.warn "EventMachine: unbind invoked in bound state" if @state == :bound
    end
    
    def send_unbind
      #raise rescue logger.debug "Unbinding, now?? #{$!.backtrace[1..5].join("\n")}"
      write_pdu Pdu::Unbind.new
      # leave it to the subclass to process the UnbindResponse
      @state = :unbound
    end

    # process common PDUs
    # returns true if no further processing necessary
    def process_pdu(pdu)      
      case pdu
      when Pdu::EnquireLinkResponse
        # nop
      when Pdu::EnquireLink
        write_pdu(Pdu::EnquireLinkResponse.new(pdu.sequence_number))
      when Pdu::Unbind
        @state = :unbound
        write_pdu(Pdu::UnbindResponse.new(pdu.sequence_number, Pdu::Base::ESME_ROK))
        EventMachine::stop_event_loop
      when Pdu::UnbindResponse      
        logger.info "Unbound OK. Closing connection."
        close_connection
      when Pdu::GenericNack
        logger.warn "Received NACK! (error code #{pdu.error_code})."
        # we don't take this lightly: stop the event loop
        EventMachine::stop_event_loop
      else
        logger.warn "(#{self.class.name}) Received unexpected PDU: #{pdu.to_human}."
        EventMachine::stop_event_loop                
      end
    end
    
    private  
    def write_pdu(pdu)
      logger.debug "<- #{pdu.to_human}"
      send_data pdu.data
    end

    def read_pdu(data)
      pdu = nil
      # we may either receive a new request or a response to a previous response.
      begin        
        pdu = Pdu::Base.create(data)
        if !pdu
          logger.warn "Not able to parse PDU!"
        else
          logger.debug "-> " + pdu.to_human          
        end
      rescue Exception => ex
        logger.error "Exception while reading PDUs: #{ex} in #{ex.backtrace[0]}"
        raise
      end
      pdu
    end    
  end
end
