/* Copyright (c) 2014 Quanta Research Cambridge, Inc
 *
 * Permission is hereby granted, free of charge, to any person obtaining a
 * copy of this software and associated documentation files (the "Software"),
 * to deal in the Software without restriction, including without limitation
 * the rights to use, copy, modify, merge, publish, distribute, sublicense,
 * and/or sell copies of the Software, and to permit persons to whom the
 * Software is furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included
 * in all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS
 * OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL
 * THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
 * FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
 * DEALINGS IN THE SOFTWARE.
 */
// bsv libraries
import Vector::*;
import FIFO::*;
import Connectable::*;

// portz libraries
import CtrlMux::*;
import Portal::*;
import Leds::*;
import MemTypes::*;
import MMU::*;
import MemServer::*;
import MemPortal::*;

// generated by tool
import Simple::*;

import MMURequest::*;
import MMUIndication::*;
import MMUIndication::*;
import SharedMemoryPortalConfig::*;
import MemServerIndication::*;

// defined by user
import SimpleIF::*;

typedef enum {SimpleIndication, SimpleRequest,
	      MMURequest, MMUIndication, MemServerIndication, ConfigWrapper} IfcNames deriving (Eq,Bits);

module mkConnectalTop(StdConnectalDmaTop#(PhysAddrWidth));

   // instantiate user portals
   SimpleProxy simpleIndicationProxy <- mkSimpleProxy(SimpleIndication);
   Simple simpleRequest <- mkSimple(simpleIndicationProxy.ifc);
   SimpleWrapperPortal simpleRequestWrapper <- mkSimpleWrapperPortal(SimpleRequest,simpleRequest);
   
   SharedMemoryPortal#(64) echoRequestSharedMemoryPortal <- mkSharedMemoryPortal(simpleRequestWrapper.portalIfc);
   SharedMemoryPortalConfigWrapper configWrapper <- mkSharedMemoryPortalConfigWrapper(ConfigWrapper, echoRequestSharedMemoryPortal.cfg);

   let readClients = cons(echoRequestSharedMemoryPortal.readClient, nil);
   let writeClients = cons(echoRequestSharedMemoryPortal.writeClient, nil);

   MemServerIndicationProxy memServerIndicationProxy <- mkMemServerIndicationProxy(MemServerIndication);
   MMUIndicationProxy mmuIndicationProxy <- mkMMUIndicationProxy(MMUIndication);
   MMU#(PhysAddrWidth) mmu <- mkMMU(0, True, mmuIndicationProxy.ifc);
   MMURequestWrapper mmuRequestWrapper <- mkMMURequestWrapper(MMURequest, mmu.request);
   MemServer#(PhysAddrWidth,64,1) dma <- mkMemServerRW(memServerIndicationProxy.ifc, readClients, writeClients, cons(mmu,nil));

   Vector#(5,StdPortal) portals;
   portals[0] = simpleIndicationProxy.portalIfc;
   portals[1] = mmuRequestWrapper.portalIfc;
   portals[2] = mmuIndicationProxy.portalIfc;
   portals[3] = configWrapper.portalIfc;
   portals[4] = memServerIndicationProxy.portalIfc;
   let ctrl_mux <- mkSlaveMux(portals);
   
   interface interrupt = getInterruptVector(portals);
   interface slave = ctrl_mux;
   interface masters = dma.masters;
   interface leds = default_leds;

endmodule : mkConnectalTop


