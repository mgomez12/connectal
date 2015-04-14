// Copyright (c) 2014 Quanta Research Cambridge, Inc.

// Permission is hereby granted, free of charge, to any person
// obtaining a copy of this software and associated documentation
// files (the "Software"), to deal in the Software without
// restriction, including without limitation the rights to use, copy,
// modify, merge, publish, distribute, sublicense, and/or sell copies
// of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:

// The above copyright notice and this permission notice shall be
// included in all copies or substantial portions of the Software.

// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
// EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
// MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
// NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS
// BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN
// ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
// CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.
import Vector::*;
import GetPut::*;
import Clocks :: *;
import BRAMFIFO::*;
import MemTypes::*;
import ClientServer::*;
import Pipe::*;
import MemwriteEngine::*;
import HostInterface::*;
import IserdesDatadeser::*;
import IserdesDatadeserIF::*;
import Connectable :: *;
import FIFO::*;
import MemServer::*;
import MMU::*;
import Portal::*;
import HostInterface::*;
import XilinxCells::*;
import ConnectalClocks::*;
import Gearbox::*;
import ConnectalSpi::*;
import ImageonVita::*;
import HDMI::*;
import YUV::*;
import ConnectalXilinxCells::*;

Bit#(10) imageDataTag = 10'h035;
Bit#(10) otherDataTag = 10'h015;

typedef struct {
    Bit#(2) monitor;
    Bit#(32) count;
} MonitorCount deriving (Bits, Eq);

interface ImageonSensorIndication;
    method Action spi_response(Bit#(32) v);
endinterface

interface ImageonCaptureRequest;
    method Action set_trigger_cnt(Bit#(32) v);
    method Action startWrite(Bit#(32) pointer, Bit#(32) numBytes);
    method Action set_host_oe(Bit#(1) v);
    method Action put_spi_request(Bit#(32) v);
    method Action set_i2c_mux_reset_n(Bit#(1) v);
endinterface

interface ImageonCapturePins;
    method Bit#(1) io_vita_clk_pll();
    method Bit#(1) io_vita_reset_n();
    method Vector#(3, ReadOnly#(Bit#(1))) io_vita_trigger();
    method Action io_vita_monitor(Bit#(2) v);
    interface SpiPins spi;
    method Bit#(1) i2c_mux_reset_n();
    interface Clock imageon_deleteme_unused_clock;
    interface Reset imageon_deleteme_unused_reset;
    interface ImageonSerdesPins serpins;
    (* prefix="" *)
    interface HDMI#(Bit#(HdmiBits)) hdmi;
    method Action fmc_video_clk1(Bit#(1) v);
endinterface

interface ImageonCapture;
   interface ImageonSerdesRequest serdes_request;
   interface ImageonCaptureRequest capture_request;
   interface HdmiGeneratorRequest hdmi_request;
   interface Vector#(1, MemWriteClient#(64)) dmaClient;
   interface ImageonCapturePins pins;
endinterface

module mkImageonCapture#(ImageonSerdesIndication serdes_indication, ImageonSensorIndication sensor_ind, HdmiGeneratorIndication hdmi_ind)(ImageonCapture);
`ifndef BSIM
    B2C1 iclock <- mkB2C1();
    Clock fmc_imageon_clk1 <- mkClockBUFG(clocked_by iclock.c);
`else
    Clock fmc_imageon_clk1 <- exposeCurrentClock();
`endif
    Clock defaultClock <- exposeCurrentClock();
    Reset defaultReset <- exposeCurrentReset();
    ImageClocks clk <- mkImageClocks(fmc_imageon_clk1);
    Clock hdmi_clock = clk.hdmi;
    Clock imageon_clock = clk.imageon;
    Reset hdmi_reset <- mkAsyncReset(2, defaultReset, hdmi_clock);
    Reset imageon_reset <- mkAsyncReset(2, defaultReset, imageon_clock);
    SPI#(Bit#(26)) spiController <- mkSPI(1000, True);
    Reg#(Bit#(1)) i2c_mux_reset_n_reg <- mkReg(0);
    Reg#(Bool) dmaRun <- mkSyncReg(False, defaultClock, defaultReset, imageon_clock);
    Reg#(Bit#(32)) trigger_cnt_reg <- mkSyncReg(0, defaultClock, defaultReset, imageon_clock);
    Reg#(Bit#(1)) imageon_oe <- mkSyncReg(0, defaultClock, defaultReset, imageon_clock);
        //clocked_by imageon_clock, reset_by imageon_reset);

    // serdes: serial line protocol for wires from sensor (nothing sensor specific)
    ISerdes serdes <- mkISerdes(defaultClock, defaultReset, serdes_indication,
			clocked_by imageon_clock, reset_by imageon_reset);

    // mem capture
    MemwriteEngine#(64,1,1) we <- mkMemwriteEngine();
    SyncFIFOIfc#(Bit#(64)) synchronizer <- mkSyncBRAMFIFO(10, imageon_clock, imageon_reset, defaultClock, defaultReset);
    rule sync_data if (dmaRun);
        synchronizer.enq(serdes.data.capture);
    endrule
    rule send_data;
        we.dataPipes[0].enq(synchronizer.first);
        synchronizer.deq;
    endrule
    rule dma_response;
        let rv <- we.writeServers[0].response.get;
        serdes_indication.iserdes_dma('hffffffff); // request is all finished
    endrule

    SyncPulseIfc vsyncPulse <- mkSyncHandshake(hdmi_clock, hdmi_reset, imageon_clock);
    Reg#(Bit#(1))  trigger_active <- mkReg(1, clocked_by imageon_clock, reset_by imageon_reset);
    Reg#(Bit#(32)) tcounter <- mkReg(0, clocked_by imageon_clock, reset_by imageon_reset);
    rule calcTrigger;
        if (trigger_active == 1 && vsyncPulse.pulse())
            begin
            tcounter <= trigger_cnt_reg;
            trigger_active <= 0;
            end
        else
            tcounter <= tcounter - 1;
        if (trigger_active == 0 && tcounter == 0)
            trigger_active <= 1;
    endrule

    // fromSensor: sensor specific processing of serdes input, resulting in pixels
    //ImageonVita vitaItem <- mkImageonVita(imageon_oe, trigger_active, serdes.data.reset,
        //clocked_by imageon_clock, reset_by imageon_reset);
//module mkImageonVita#(Bit#(1) imageon_oe, Bit#(1) trigger_active, Bit#(1) serdes.data.reset)(ImageonVita);
    Vector#(3, ReadOnly#(Bit#(1))) vita_trigger_wire;
`ifndef BSIM
    ConnectalODDR#(Bit#(1)) pll_out <- mkConnectalODDR(ODDRParams{ddr_clk_edge:"SAME_EDGE", init:1, srtype:"ASYNC"}, clocked_by imageon_clock, reset_by imageon_reset);
    ConnectalODDR#(Bit#(1)) pll_t <- mkConnectalODDR(ODDRParams{ddr_clk_edge:"SAME_EDGE", init:1, srtype:"ASYNC"}, clocked_by imageon_clock, reset_by imageon_reset);
    Wire#(Bit#(1)) poutq <- mkDWire(0, clocked_by imageon_clock, reset_by imageon_reset);
    Wire#(Bit#(1)) ptq <- mkDWire(0, clocked_by imageon_clock, reset_by imageon_reset);
    ReadOnly#(Bit#(1)) vita_clk_pll <- mkOBUFT(poutq, ptq, clocked_by imageon_clock, reset_by imageon_reset);

    Wire#(Bit#(1)) zero_wire <- mkDWire(0, clocked_by imageon_clock, reset_by imageon_reset);
    Wire#(Bit#(1)) one_wire <- mkDWire(1, clocked_by imageon_clock, reset_by imageon_reset);
    vita_trigger_wire[2] <- mkOBUFT(zero_wire, imageon_oe, clocked_by imageon_clock, reset_by imageon_reset);
    vita_trigger_wire[1] <- mkOBUFT(one_wire, imageon_oe, clocked_by imageon_clock, reset_by imageon_reset);
    vita_trigger_wire[0] <- mkOBUFT(trigger_active, imageon_oe, clocked_by imageon_clock, reset_by imageon_reset);
    ReadOnly#(Bit#(1)) vita_reset_n_wire <- mkOBUFT(serdes.data.reset, imageon_oe, clocked_by imageon_clock, reset_by imageon_reset);

    rule pll_rule;
        poutq <= pll_out.q();
        ptq <= pll_t.q();
        pll_t.s(False);
        pll_out.s(False);
        pll_out.d1(0);
        pll_out.d2(1);
        pll_out.ce(True);
        pll_t.d1(imageon_oe);
        pll_t.d2(imageon_oe);
        pll_t.ce(True);
    endrule
`else
    let vita_clk_pll = 0;
    let vita_reset_n_wire = 0;
    vita_trigger_wire = replicate(interface ReadOnly; method Bit#(1) _read(); return 0; endmethod endinterface);
`endif
////////////endmodule
    Reg#(Bit#(1))  remapkernel_reg <- mkReg(0, clocked_by imageon_clock, reset_by imageon_reset);
    Gearbox#(4, 1, Bit#(10)) dataGearbox <- mkNto1Gearbox(imageon_clock, imageon_reset, hdmi_clock, hdmi_reset);
        //clocked_by imageon_clock, reset_by imageon_reset);

    rule frameData;
        Vector#(5, Bit#(10)) v = serdes.data.raw_data();
        if (v[0] == imageDataTag || v[0] == otherDataTag)
            begin
            Vector#(4, Bit#(10)) dor;
            for (Integer i = 0; i < 4; i = i + 1)
                if (remapkernel_reg == 0)
                    dor[i] = v[i+1];
                else
                    dor[i] = v[4-i];
            remapkernel_reg <= ~remapkernel_reg;
            dataGearbox.enq(dor);
            end
        else
            remapkernel_reg <= 0;
    endrule

    rule spiResponse;
        Bit#(26) v <- spiController.response.get();
        sensor_ind.spi_response(extend(v));
    endrule

    // hdmi: output to display
    HdmiGenerator#(Rgb888) lHdmiGenerator <- mkHdmiGenerator(defaultClock, defaultReset,
        vsyncPulse, hdmi_ind, clocked_by hdmi_clock, reset_by hdmi_reset);
    Rgb888ToYyuv converter <- mkRgb888ToYyuv(clocked_by hdmi_clock, reset_by hdmi_reset);
    mkConnection(lHdmiGenerator.rgb888, converter.rgb888);
    HDMI#(Bit#(HdmiBits)) hdmisignals <- mkHDMI(converter.yyuv, clocked_by hdmi_clock, reset_by hdmi_reset);

    Reg#(Bool) frameStart <- mkReg(False, clocked_by imageon_clock, reset_by imageon_reset);
    Reg#(Bit#(32)) frameCount <- mkReg(0, clocked_by imageon_clock, reset_by imageon_reset);
    SyncFIFOIfc#(MonitorCount) frameStartSynchronizer <- mkSyncFIFO(2, imageon_clock, imageon_reset, defaultClock);
    Wire#(Bit#(2)) monitor_wires <- mkDWire(0, clocked_by imageon_clock, reset_by imageon_reset);

   rule frameStartRule;
       Bool fs = unpack(monitor_wires[0]);
       if (fs && !frameStart) begin
	  // start of frame?
	  // need to cross the clock domain
	  frameStartSynchronizer.enq(MonitorCount{monitor:monitor_wires, count:frameCount});
	  frameCount <= frameCount + 1;
       end
      frameStart <= fs;
   endrule
   rule frameStartIndication;
      let tpl = frameStartSynchronizer.first();
      frameStartSynchronizer.deq();
      //captureIndicationProxy.ifc.frameStart(tpl.monitor, tpl.count);
   endrule

   Reg#(Bit#(10)) xsvi <- mkReg(0, clocked_by hdmi_clock, reset_by hdmi_reset);
   rule xsviConnection;
       // copy data from sensor to hdmi output
       dataGearbox.deq;
       xsvi <= dataGearbox.first[0];
   endrule
   rule xsviput;
       Bit#(32) pixel = {8'b0, xsvi[9:2], xsvi[9:2], xsvi[9:2]};
       lHdmiGenerator.pdata.put(pixel);
   endrule

   interface serdes_request = serdes.request;
   interface ImageonCaptureRequest capture_request;
       method Action set_trigger_cnt(Bit#(32) v);
           trigger_cnt_reg <= v;
           serdes.data.start_capture();
       endmethod
       method Action startWrite(Bit#(32) pointer, Bit#(32) numBytes);
           we.writeServers[0].request.put(MemengineCmd{sglId:pointer, base:0, len:truncate(numBytes), burstLen:8});
           dmaRun <= True;
       endmethod
	method Action set_host_oe(Bit#(1) v);
	    imageon_oe <= ~v;
	endmethod
        method Action put_spi_request(Bit#(32) v);
            spiController.request.put(truncate(v));
        endmethod
        method Action set_i2c_mux_reset_n(Bit#(1) v);
            i2c_mux_reset_n_reg <= v;
        endmethod
    endinterface
    interface hdmi_request = lHdmiGenerator.request;
    interface dmaClient = cons(we.dmaClient, nil);
    interface ImageonCapturePins pins;
`ifndef BSIM
        method Action fmc_video_clk1(Bit#(1) v);
            iclock.inputclock(v);
        endmethod
`endif
        method Action io_vita_monitor(Bit#(2) v);
	    monitor_wires <= v;
        endmethod
        method Bit#(1) io_vita_clk_pll();
            return vita_clk_pll;
        endmethod
        method Bit#(1) io_vita_reset_n();
            return vita_reset_n_wire;
        endmethod
        method Vector#(3, ReadOnly#(Bit#(1))) io_vita_trigger();
            return vita_trigger_wire;
        endmethod
        method Bit#(1) i2c_mux_reset_n(); return i2c_mux_reset_n_reg; endmethod
        interface SpiPins spi = spiController.pins;
        interface imageon_deleteme_unused_clock = imageon_clock;
        interface imageon_deleteme_unused_reset = imageon_reset;
        interface ImageonSerdesPins serpins = serdes.pins;
        interface HDMI hdmi = hdmisignals;
    endinterface
endmodule
