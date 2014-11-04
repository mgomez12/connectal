
// Copyright (c) 2013-2014 Quanta Research Cambridge, Inc.

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

#include "portal.h"
#include "sock_utils.h"

#ifndef __KERNEL__
#include <stdio.h>
#include <stdlib.h>
#include <errno.h>
#include <string.h>
#include <unistd.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <semaphore.h>
#include <pthread.h>
#include <assert.h>
#include <netdb.h>

int bsim_fpga_map[MAX_BSIM_PORTAL_ID];
static pthread_mutex_t socket_mutex;
int global_sockfd = -1;
static int trace_socket;// = 1;

int init_connecting(const char *arg_name, PortalSocketParam *param)
{
  int connect_attempts = 0;
  int sockfd;

  if (param) {
       sockfd = socket(param->addr->ai_family, param->addr->ai_socktype, param->addr->ai_protocol);
       if (sockfd == -1) {
           fprintf(stderr, "%s[%d]: socket error %s\n",__FUNCTION__, sockfd, strerror(errno));
           exit(1);
       }
  if (trace_socket)
    fprintf(stderr, "%s (%s) trying to connect...\n",__FUNCTION__, arg_name);
  while (connect(sockfd, param->addr->ai_addr, param->addr->ai_addrlen) == -1) {
    if(connect_attempts++ > 16){
      fprintf(stderr,"%s (%s) connect error %s\n",__FUNCTION__, arg_name, strerror(errno));
      exit(1);
    }
    if (trace_socket)
      fprintf(stderr, "%s (%s) retrying connection\n",__FUNCTION__, arg_name);
    sleep(1);
  }
  }
  else {
  if ((sockfd = socket(AF_UNIX, SOCK_STREAM, 0)) == -1) {
    fprintf(stderr, "%s (%s) socket error %s\n",__FUNCTION__, arg_name, strerror(errno));
    exit(1);
  }

  if (trace_socket)
    fprintf(stderr, "%s (%s) trying to connect...\n",__FUNCTION__, arg_name);
  struct sockaddr_un local;
  local.sun_family = AF_UNIX;
  strcpy(local.sun_path, arg_name);
  while (connect(sockfd, (struct sockaddr *)&local, strlen(local.sun_path) + sizeof(local.sun_family)) == -1) {
    if(connect_attempts++ > 16){
      fprintf(stderr,"%s (%s) connect error %s\n",__FUNCTION__, arg_name, strerror(errno));
      exit(1);
    }
    if (trace_socket)
      fprintf(stderr, "%s (%s) retrying connection\n",__FUNCTION__, arg_name);
    sleep(1);
  }
  }
  fprintf(stderr, "%s (%s) connected.  Attempts %d\n",__FUNCTION__, arg_name, connect_attempts);
  return sockfd;
}

void connect_to_bsim(void)
{
  static PortalInternal p;
  if (global_sockfd != -1)
    return;
  global_sockfd = init_connecting(SOCKET_NAME, NULL);
  pthread_mutex_init(&socket_mutex, NULL);
  unsigned int last = 0;
  unsigned int idx = 0;
  while(!last && idx < 32){
    volatile unsigned int *ptr=(volatile unsigned int *)(long)(idx * PORTAL_BASE_OFFSET);
    volatile unsigned int *idp = &ptr[PORTAL_CTRL_REG_PORTAL_ID];
    volatile unsigned int *topp = &ptr[PORTAL_CTRL_REG_TOP];
    p.fpga_number = idx;
    unsigned int id = bsimfunc.read(&p, &idp);
    last = bsimfunc.read(&p, &topp);
    assert(id < MAX_BSIM_PORTAL_ID);
    bsim_fpga_map[id] = idx++;
    //fprintf(stderr, "%s bsim_fpga_map[%d]=%d (%d)\n", __FUNCTION__, id, bsim_fpga_map[id], last);
  }  
}

static int init_socketResp(struct PortalInternal *pint, void *aparam)
{
    PortalSocketParam *param = (PortalSocketParam *)aparam;
    char buff[128];
    sprintf(buff, "SWSOCK%d", pint->fpga_number);
    pint->fpga_fd = init_listening(buff, param);
    pint->map_base = (volatile unsigned int*)malloc(pint->reqsize);
    return 0;
}
static int init_socketInit(struct PortalInternal *pint, void *aparam)
{
    PortalSocketParam *param = (PortalSocketParam *)aparam;
    char buff[128];
    sprintf(buff, "SWSOCK%d", pint->fpga_number);
    pint->fpga_fd = init_connecting(buff, param);
    pint->accept_finished = 1;
    pint->map_base = (volatile unsigned int*)malloc(pint->reqsize);
    return 0;
}
static volatile unsigned int *mapchannel_socket(struct PortalInternal *pint, unsigned int v)
{
    return &pint->map_base[1];
}
void send_socket(struct PortalInternal *pint, unsigned int hdr, int sendFd)
{
    pint->map_base[0] = hdr;
    portalSendFd(pint->fpga_fd, (void *)pint->map_base, (hdr & 0xffff) * sizeof(uint32_t), sendFd);
}
int recv_socket(struct PortalInternal *pint, volatile unsigned int *buffer, int len, int *recvfd)
{
    return portalRecvFd(pint->fpga_fd, (void *)buffer, len * sizeof(uint32_t), recvfd);
}
int event_socket(struct PortalInternal *pint)
{
    int event_socket_fd;
    /* sw portal */
    if (pint->accept_finished) { /* connection established */
       int len = portalRecvFd(pint->fpga_fd, (void *)pint->map_base, sizeof(uint32_t), &event_socket_fd);
       if (len == 0 || (len == -1 && errno == EAGAIN))
           return -1;
       if (len <= 0) {
           fprintf(stderr, "%s[%d]: read error %d\n",__FUNCTION__, pint->fpga_fd, errno);
           exit(1);
       }
       pint->handler(pint, *pint->map_base >> 16, event_socket_fd);
    }
    else { /* have not received connection yet */
printf("[%s:%d]beforeacc %d\n", __FUNCTION__, __LINE__, pint->fpga_fd);
        int sockfd = accept_socket(pint->fpga_fd);
        if (sockfd != -1) {
printf("[%s:%d]afteracc %d\n", __FUNCTION__, __LINE__, sockfd);
            pint->accept_finished = 1;
            return sockfd;
        }
    }
    return -1;
}
PortalItemFunctions socketfuncResp = {
    init_socketResp, read_portal_memory, write_portal_memory, write_fd_portal_memory, mapchannel_socket, mapchannel_socket,
    send_socket, recv_socket, busy_portal_null, enableint_portal_null, event_socket};
PortalItemFunctions socketfuncInit = {
    init_socketInit, read_portal_memory, write_portal_memory, write_fd_portal_memory, mapchannel_socket, mapchannel_socket,
    send_socket, recv_socket, busy_portal_null, enableint_portal_null, event_socket};

/*
 * BSIM
 */
static struct memresponse shared_response;
static int shared_response_valid;
static uint32_t interrupt_value;
int poll_response(int id)
{
  int recvFd;
  if (!shared_response_valid) {
      if (portalRecvFd(global_sockfd, &shared_response, sizeof(shared_response), &recvFd) == sizeof(shared_response)) {
          if (shared_response.portal == MAGIC_PORTAL_FOR_SENDING_INTERRUPT)
              interrupt_value = shared_response.data;
          else
              shared_response_valid = 1;
      }
  }
  return shared_response_valid && shared_response.portal == id;
}
unsigned int bsim_poll_interrupt(void)
{
  if (global_sockfd == -1)
      return 0;
  pthread_mutex_lock(&socket_mutex);
  poll_response(-1);
  pthread_mutex_unlock(&socket_mutex);
  return interrupt_value;
}
/* functions called by READL() and WRITEL() macros in application software */
unsigned int tag_counter;
static unsigned int read_portal_bsim(PortalInternal *pint, volatile unsigned int **addr)
{
  struct memrequest foo = {pint->fpga_number, 0,*addr,0};

  pthread_mutex_lock(&socket_mutex);
  foo.data_or_tag = tag_counter++;
  portalSendFd(global_sockfd, &foo, sizeof(foo), -1);
  while (!poll_response(pint->fpga_number)) {
      struct timeval tv = {};
      tv.tv_usec = 10000;
      select(0, NULL, NULL, NULL, &tv);
  }
  unsigned int rc = shared_response.data;
  shared_response_valid = 0;
  pthread_mutex_unlock(&socket_mutex);
  return rc;
}

static void write_portal_bsim(PortalInternal *pint, volatile unsigned int **addr, unsigned int v)
{
  struct memrequest foo = {pint->fpga_number, 1,*addr,v};

  portalSendFd(global_sockfd, &foo, sizeof(foo), -1);
}
void write_portal_fd_bsim(PortalInternal *pint, volatile unsigned int **addr, unsigned int v)
{
  struct memrequest foo = {pint->fpga_number, 1,*addr,v};

printf("[%s:%d] fd %d\n", __FUNCTION__, __LINE__, v);
  portalSendFd(global_sockfd, &foo, sizeof(foo), v);
}
#else // __KERNEL__

/*
 * Used when running application in kernel and BSIM in userspace
 */

#include <linux/kernel.h>
#include <linux/uaccess.h> // copy_to/from_user
#include <linux/mutex.h>
#include <linux/semaphore.h>
#include <linux/slab.h>
#include <linux/dma-buf.h>

extern struct semaphore bsim_start;
static struct semaphore bsim_avail;
static struct semaphore bsim_have_response;
void memdump(unsigned char *p, int len, char *title);
static int have_request;
static struct memrequest upreq;
static struct memresponse downresp;
extern int bsim_relay_running;
extern int main_program_finished;

ssize_t connectal_kernel_read (struct file *f, char __user *arg, size_t len, loff_t *data)
{
    int err;
    if (!bsim_relay_running)
        up(&bsim_start);
    bsim_relay_running = 1;
    if (main_program_finished)
        return 0;          // all done!
    if (!have_request)
        return -EAGAIN;
    if (len > sizeof(upreq))
        len = sizeof(upreq);
    if (upreq.write_flag == MAGIC_PORTAL_FOR_SENDING_FD) // part of sock_fd_write() processing
        upreq.addr = (void *)(long)dma_buf_fd((struct dma_buf *)upreq.addr, O_CLOEXEC); /* get an fd in user process!! */
    err = copy_to_user((void __user *) arg, &upreq, len);
    have_request = 0;
    up(&bsim_avail);
    return len;
}
ssize_t connectal_kernel_write (struct file *f, const char __user *arg, size_t len, loff_t *data)
{
    int err;
    if (len > sizeof(downresp))
        len = sizeof(downresp);
    err = copy_from_user(&downresp, (void __user *) arg, len);
    if (!err)
        up(&bsim_have_response);
    return len;
}

void connect_to_bsim(void)
{
    printk("[%s:%d]\n", __FUNCTION__, __LINE__);
    if (bsim_relay_running)
        return;
    sema_init (&bsim_avail, 1);
    sema_init (&bsim_have_response, 0);
    down_interruptible(&bsim_start);
}

static unsigned int read_portal_bsim(volatile unsigned int *addr, int id)
{
    struct memrequest foo = {id, 0,addr,0};
    //printk("[%s:%d]\n", __FUNCTION__, __LINE__);
    if (main_program_finished)
        return 0;
    down_interruptible(&bsim_avail);
    memcpy(&upreq, &foo, sizeof(upreq));
    have_request = 1;
    down_interruptible(&bsim_have_response);
    return downresp.data;
}

static void write_portal_bsim(volatile unsigned int *addr, unsigned int v, int id)
{
    struct memrequest foo = {id, 1,addr,v};
    //printk("[%s:%d]\n", __FUNCTION__, __LINE__);
    if (main_program_finished)
        return;
    down_interruptible(&bsim_avail);
    memcpy(&upreq, &foo, sizeof(upreq));
    have_request = 1;
}
void write_portal_fd_bsim(volatile unsigned int *addr, unsigned int v, int id)
{
    struct memrequest foo = {id, MAGIC_PORTAL_FOR_SENDING_FD,addr,v};
    struct file *fmem;

    if (main_program_finished)
        return;
    fmem = fget(v);
    foo.addr = fmem->private_data;
    printk("[%s:%d] fd %x dmabuf %p\n", __FUNCTION__, __LINE__, v, foo.addr);
    fput(fmem);
    down_interruptible(&bsim_avail);
    memcpy(&upreq, &foo, sizeof(upreq));
    have_request = 1;
    down_interruptible(&bsim_have_response);
}
#endif
static int init_bsim(struct PortalInternal *pint, void *param)
{
#ifdef BSIM
    extern int bsim_fpga_map[MAX_BSIM_PORTAL_ID];
    connect_to_bsim();
    assert(pint->fpga_number < MAX_BSIM_PORTAL_ID);
    pint->fpga_number = bsim_fpga_map[pint->fpga_number];
    pint->map_base = (volatile unsigned int*)(long)(pint->fpga_number * PORTAL_BASE_OFFSET);
    pint->item->enableint(pint, 1);
#endif
    return 0;
}
int event_portal_bsim(struct PortalInternal *pint)
{
#ifdef BSIM
    if (pint->fpga_fd == -1 && !bsim_poll_interrupt())
        return -1;
#endif
    return event_hardware(pint);
}
PortalItemFunctions bsimfunc = {
    init_bsim, read_portal_bsim, write_portal_bsim, write_portal_fd_bsim, mapchannel_hardware, mapchannel_hardware,
    send_portal_null, recv_portal_null, busy_hardware, enableint_hardware, event_portal_bsim};
