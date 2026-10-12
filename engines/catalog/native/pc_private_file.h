#pragma once
#include <cstdio>
#include <cstdint>
#include <stdexcept>
#include <mutex>
#include <limits>
#include <cerrno>
#include <cstdlib>
#include <cwchar>
#ifdef _WIN32
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#include <sddl.h>
#include <aclapi.h>
#include <bcrypt.h>
#include <io.h>
#include <fcntl.h>
#else
#include <unistd.h>
#include <sys/stat.h>
#include <fcntl.h>
#endif

// One exclusive file, one held identity, no directory enumeration or path
// deletion. The Windows handle has an owner-only protected DACL, no sharing,
// and DELETE_ON_CLOSE; POSIX tmpfile is already unlinked. The wrapper retains
// the exact handle until actual final close and serializes random-access I/O.
class PcPrivateFile final {
    FILE *file=nullptr;
    mutable std::mutex mutex;
    uint64_t extent=0;
    bool sealed=false;
#ifdef _WIN32
    HANDLE handle=INVALID_HANDLE_VALUE;
    DWORD volume=0,indexHigh=0,indexLow=0;
#else
    int fd=-1;dev_t device=0;ino_t inode=0;
#endif
    [[noreturn]] static void fail(const char *message){throw std::runtime_error(message);}
    void checkLocked(bool acceptSize=false) const {
#ifdef _WIN32
        BY_HANDLE_FILE_INFORMATION info{};
        if(!GetFileInformationByHandle(handle,&info)||GetFileType(handle)!=FILE_TYPE_DISK||
           info.dwFileAttributes&(FILE_ATTRIBUTE_DIRECTORY|FILE_ATTRIBUTE_REPARSE_POINT)||
           info.nNumberOfLinks!=1||info.dwVolumeSerialNumber!=volume||
           info.nFileIndexHigh!=indexHigh||info.nFileIndexLow!=indexLow)fail("private scratch held identity changed");
        const uint64_t bytes=(uint64_t(info.nFileSizeHigh)<<32)|info.nFileSizeLow;
#else
        struct stat info{};
        if(fstat(fd,&info)||!S_ISREG(info.st_mode)||info.st_nlink!=0||info.st_uid!=getuid()||
           info.st_dev!=device||info.st_ino!=inode||(info.st_mode&0777)!=(sealed?0444:0600)||info.st_size<0)
            fail("private scratch held identity changed");
        const uint64_t bytes=uint64_t(info.st_size);
#endif
        if(!acceptSize&&bytes!=extent)fail("private scratch extent changed");
    }
    void seekLocked(uint64_t position) const {
        if(position>uint64_t(INT64_MAX))fail("private scratch offset overflow");
#ifdef _WIN32
        if(_fseeki64(file,static_cast<__int64>(position),SEEK_SET))fail("private scratch seek failed");
#else
        if(fseeko(file,static_cast<off_t>(position),SEEK_SET))fail("private scratch seek failed");
#endif
    }
public:
    PcPrivateFile() {
#ifdef _WIN32
        PSECURITY_DESCRIPTOR descriptor=nullptr;
        if(!ConvertStringSecurityDescriptorToSecurityDescriptorW(L"D:P(A;;GA;;;OW)",SDDL_REVISION_1,&descriptor,nullptr))
            fail("private scratch security descriptor");
        SECURITY_ATTRIBUTES attributes{sizeof(SECURITY_ATTRIBUTES),descriptor,FALSE};
        wchar_t folder[MAX_PATH+1]{};DWORD n=GetTempPathW(MAX_PATH,folder);
        if(!n||n>=MAX_PATH){LocalFree(descriptor);fail("private scratch temporary directory");}
        for(unsigned attempt=0;attempt<32&&handle==INVALID_HANDLE_VALUE;++attempt) {
            unsigned char random[16];
            if(BCryptGenRandom(nullptr,random,sizeof(random),BCRYPT_USE_SYSTEM_PREFERRED_RNG)!=0){LocalFree(descriptor);fail("private scratch random identity");}
            wchar_t path[MAX_PATH+65]{};wcscpy_s(path,folder);wcscat_s(path,L"LensWorks-Decode-");
            size_t offset=wcslen(path);const wchar_t digits[]=L"0123456789abcdef";
            for(unsigned i=0;i<16;++i){path[offset+2*i]=digits[random[i]>>4];path[offset+2*i+1]=digits[random[i]&15];}
            path[offset+32]=0;
            handle=CreateFileW(path,GENERIC_READ|GENERIC_WRITE|DELETE|READ_CONTROL,0,&attributes,CREATE_NEW,
                FILE_ATTRIBUTE_TEMPORARY|FILE_FLAG_DELETE_ON_CLOSE|FILE_FLAG_OPEN_REPARSE_POINT,nullptr);
            if(handle==INVALID_HANDLE_VALUE&&GetLastError()!=ERROR_FILE_EXISTS){LocalFree(descriptor);fail("private scratch exclusive create");}
        }
        LocalFree(descriptor);
        if(handle==INVALID_HANDLE_VALUE)fail("private scratch exclusive generation exhausted");
        BY_HANDLE_FILE_INFORMATION info{};
        if(!GetFileInformationByHandle(handle,&info)){CloseHandle(handle);fail("private scratch initial identity");}
        volume=info.dwVolumeSerialNumber;indexHigh=info.nFileIndexHigh;indexLow=info.nFileIndexLow;
        // Verify the actual owner against the creating token, not a path/ACL guess.
        PSID owner=nullptr;PSECURITY_DESCRIPTOR actual=nullptr;HANDLE token=nullptr;DWORD size=0;
        bool owned=GetSecurityInfo(handle,SE_FILE_OBJECT,OWNER_SECURITY_INFORMATION,&owner,nullptr,nullptr,nullptr,&actual)==ERROR_SUCCESS&&
            OpenProcessToken(GetCurrentProcess(),TOKEN_QUERY,&token);
        if(owned){GetTokenInformation(token,TokenUser,nullptr,0,&size);}
        void *user=owned&&size?std::malloc(size):nullptr;
        owned=owned&&user&&GetTokenInformation(token,TokenUser,user,size,&size)&&EqualSid(owner,static_cast<TOKEN_USER *>(user)->User.Sid);
        if(user)std::free(user);if(actual)LocalFree(actual);if(token)CloseHandle(token);
        if(!owned){CloseHandle(handle);fail("private scratch owner mismatch");}
        int fd=_open_osfhandle(reinterpret_cast<intptr_t>(handle),_O_RDWR|_O_BINARY);
        if(fd<0){CloseHandle(handle);fail("private scratch CRT ownership");}
        file=_fdopen(fd,"w+b");if(!file){_close(fd);fail("private scratch stream ownership");}
#else
        file=tmpfile();if(!file)fail("private scratch exclusive create");fd=fileno(file);
        struct stat info{};
        if(fstat(fd,&info)||!S_ISREG(info.st_mode)||info.st_nlink!=0||info.st_uid!=getuid()||fchmod(fd,0600)||
           fcntl(fd,F_SETFD,FD_CLOEXEC)) {
            fclose(file);file=nullptr;fail("private scratch initial identity");
        }
        device=info.st_dev;inode=info.st_ino;
#endif
        try{checkLocked();}catch(...){fclose(file);file=nullptr;throw;}
    }
    ~PcPrivateFile(){if(file)fclose(file);}
    PcPrivateFile(const PcPrivateFile &)=delete;PcPrivateFile &operator=(const PcPrivateFile &)=delete;
    FILE *writerStream(){std::lock_guard<std::mutex> lock(mutex);checkLocked();if(sealed)fail("sealed scratch writer");return file;}
    void acceptWriter(uint64_t maximum) {
        std::lock_guard<std::mutex> lock(mutex);if(sealed||fflush(file))fail("private scratch writer flush");checkLocked(true);
#ifdef _WIN32
        if(_fseeki64(file,0,SEEK_END))fail("private scratch writer extent");const auto n=_ftelli64(file);
#else
        if(fseeko(file,0,SEEK_END))fail("private scratch writer extent");const auto n=ftello(file);
#endif
        if(n<0||uint64_t(n)>maximum)fail("private scratch writer exceeded admitted extent");extent=uint64_t(n);checkLocked();
    }
    void resize(uint64_t bytes) {
        std::lock_guard<std::mutex> lock(mutex);checkLocked();if(sealed||bytes>uint64_t(INT64_MAX))fail("private scratch resize");
        if(fflush(file))fail("private scratch flush");
#ifdef _WIN32
        if(_chsize_s(_fileno(file),bytes))fail("private scratch resize failed");
#else
        if(ftruncate(fd,static_cast<off_t>(bytes)))fail("private scratch resize failed");
#endif
        extent=bytes;checkLocked();
    }
    void seal() {
        std::lock_guard<std::mutex> lock(mutex);checkLocked();if(fflush(file))fail("private scratch publication flush");
#ifdef _WIN32
        if(_commit(_fileno(file)))fail("private scratch publication sync");
#else
        if(fsync(fd)||fchmod(fd,0444))fail("private scratch publication sync");
#endif
        sealed=true;checkLocked();
    }
    uint64_t size() const {std::lock_guard<std::mutex> lock(mutex);checkLocked();return extent;}
    void verify() const {std::lock_guard<std::mutex> lock(mutex);checkLocked();}
    void transfer(void *bytes,uint64_t position,size_t count,bool write) {
        std::lock_guard<std::mutex> lock(mutex);checkLocked();
        if(position>extent||count>extent-position||(write&&sealed))fail("private scratch transfer range/state");
        seekLocked(position);auto *cursor=static_cast<unsigned char *>(bytes);
        while(count){size_t n=write?fwrite(cursor,1,count,file):fread(cursor,1,count,file);if(!n)fail("private scratch short I/O");cursor+=n;count-=n;}
        if(write&&fflush(file))fail("private scratch write flush");checkLocked();
    }
    void read(void *bytes,uint64_t position,size_t count){transfer(bytes,position,count,false);}
};
