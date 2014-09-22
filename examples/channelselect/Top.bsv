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

// bsv libraries
import Vector::*;
import GetPut::*;
import Connectable :: *;
import FIFO::*;

// portz libraries
import Portal::*;
import Directory::*;
import CtrlMux::*;
import Portal::*;
import Leds::*;

import MemPortal::*;
import MemTypes::*;
import MemServer::*;

// defined by user
import DDSTestInterfaces::*;
import DDSTest::*;
import ChannelSelectTestInterfaces::*;
import ChannelSelectTest::*;

// generated by tool
import ChannelSelectTestRequestWrapper::*;
import ChannelSelectTestIndicationProxy::*;
import DDSTestRequestWrapper::*;
import DDSTestIndicationProxy::*;


typedef enum { ChannelSelectTestIndication, ChannelSelectTestRequest, DDSTestIndication, DDSTestRequest} IfcNames deriving (Eq,Bits);

module mkPortalTop(StdPortalTop#(PhysAddrWidth));

   ChannelSelectTestIndicationProxy channelSelectTestIndicationProxy <- mkChannelSelectTestIndicationProxy(ChannelSelectTestIndication);
   
   ChannelSelectTestRequest channelSelectTestRequest <- mkChannelSelectTestRequest(channelSelectTestIndicationProxy.ifc);

   ChannelSelectTestRequestWrapper channelSelectTestRequestWrapper <- mkChannelSelectTestRequestWrapper(ChannelSelectTestRequest, channelSelectTestRequest);

   DDSTestIndicationProxy ddsTestIndicationProxy <- mkDDSTestIndicationProxy(DDSTestIndication);
   DDSTestRequest ddsTestRequest <- mkDDSTestRequest(ddsTestIndicationProxy.ifc);
   DDSTestRequestWrapper ddsTestRequestWrapper <- mkDDSTestRequestWrapper(DDSTestRequest, ddsTestRequest);

   Vector#(4,StdPortal) portals;
   portals[0] = channelSelectTestRequestWrapper.portalIfc;
   portals[1] = channelSelectTestIndicationProxy.portalIfc; 
   portals[2] = ddsTestRequestWrapper.portalIfc;
   portals[3] = ddsTestIndicationProxy.portalIfc; 

   // instantiate system directory
   StdDirectory dir <- mkStdDirectory(portals);
   let ctrl_mux <- mkSlaveMux(dir,portals);
   
   interface interrupt = getInterruptVector(portals);
   interface slave = ctrl_mux;
   interface masters = nil;
   interface leds = default_leds;

endmodule : mkPortalTop
