# lab5 File System, Spawn and Shell

## introduction

在这个实验中，您将会实现`spawn`（加载和运行磁盘中可执行文件的调用），您将会充实你的内核，使其在控制台中运行shell，这些特征需要文件系统，这个实验中会介绍一个简单的读写文件系统。

### Getting Started
首先需要merge lab4，然后lab5中新加入了新的文件，介绍如下：
| 文件名| 说明 |
-----|---
|`fs/fs.c` |操作文件系统的硬盘代码|
| `fs/bc.c`| 简单的block cache在用户态的page fault的实现 |
|`sf/ide.c` | 最小的基于POI的(非中断驱动) IDE驱动代码 |
| `fs/serv.c` | 使用文件系统IPCs与客户端环境交互的文件系统服务器 |
| `lib/fd.c`| 实现通用类UNIX文件描述符的实现代码 |
| `lib/file.c`| 磁盘类型驱动，实现了文件系统的IPC客户端 | 
| `lib/console.c` | 控制台输入输出文件类型的驱动| 
| `lib/spawn.c` |spawn库调用代码框架 |

在实验之前，你暂时需要注释掉`kern/init.c`中的`ENV_CREATE(fs_fs)`以及`lib/exit.c`中的`close_all()`，然后运行pingpong、primes、forktree test测试合并后的代码是否有bug，如果没有即可开始lab5的实验。

## 文件系统的初步介绍
你即将创建的文件系统要比实际的文件系统要简单的多，不过他依然十分强大，提供了基本的特征包括在层级目录结构中进行创建、读取、写和删除文件。

我们目前开发了一个只有单用户的操作系统，并提供了充足的保护对bug进行捕获，但是不能对多个用户进行隔离，因此，我们文件系统不支持UNIX的文件所有权与权限，我们的文件系统同样也不支持硬链接与符号链接、时间戳、或者特殊的设备文件。

### 磁盘文件系统结构
大多数UNIX文件系统将磁盘空间分成两个部分，一个是inode区域和数据区域，UNIX文件系统对每个文件分配一个inode；一个文件inode保存朱勇的元数据，包括文件的stat属性和指向其数据块的指针。数据区域被分成更大的数据块（8kB或者更大的区域），文件系统将文件数据与目录元数据存放在此，目录入口包括文件名称和指向inode的指针;一个硬链接文件如果多个目录入口指向同一个文件的inode。既然我们的文件系统不支持硬链接，我们不需要这种级别的间接性，因此可以简化 ，将文件的或者其子目录的元数据存储在描述该文件的目录条目中。

也就是说，与一般的文件系统采用的(fileName -> inode -> fileData)不太一致的情况是JOS的文件系统忽略了inode部分，直接采用(fileName -> fileData)

#### Sector and Block
如同内存与Flash存储设备一样，很多磁盘的的访问粒度叫做Sector，在JOS中Sector是512字节。而文件系统实际分配与使用的是Block，通俗的来说，Sector是由硬件决定的，而Block是操作系统对硬件的抽象，那么很显然，便于管理，Block应该是Sector的倍数关系。

 UNIX xv6操作系统采用block也是512字节，当然大部分现代操作系统的block更大一些，因为现在的磁盘越来越大了。在JOS中我们的Block采用4096 字节，也就是4kB。

 ##### SuperBlock
 文件系统一般保存一个确定的磁盘块（比如在最开始或者最末尾）用于记录整个文件系统的元数据比如BlockSize，磁盘大小，根目录元数据，文件系统最后一次挂载时间，文件系统最后一次出错的时间等等，这个特殊的block叫超级块。

 ##### 文件元数据
 在JOS中文件的元数据描述在`inc/fs.h`中的结构体`struct File`中，元数据包括文件名称，大小，类型，指向包含文件的块的指针。就像之前描述的那样，我们没有inode，所以元数据存储在磁盘的目录入口中，为了简化，我们使用Files结构体代表文件元数据，所以其即在内存中，也在磁盘中。

在File结构体中，数组`f_direct`包含了前10个block的block number，我们将其称作文件直接块（direct block），对于在40KB以下的文件，File结构体中可以直接存储其所有的block number，对于大于40KB的文件，我们分配一个额外的block，叫做文件的非直接块（indirect block），最多有1024个块编号，所以，本文件系统最多支持1034个block，也就是1034 * 4 KB，为了支持更大的文件，实际的文件系统，一般支持两个或者三个非直接块。
![文件图片](./file.png)

##### 目录与实际文件
在File结构体中，可以描述普通文件或者目录，通过`type`字段进行描述，不同的是，对于目录文件，操作系统并不将其数据块解析为普通文件，而是将其解析为一系列的File结构体作为该目录下的文件与子目录。

在我们文件系统中的superBlock，包含了一个File结构体，保存着根目录的元数据。目录文件的内容是一系列的File结构体，描述根目录下的文件与子目录，同样根目录的子目录也包含更多的File结构体，代表子目录的子目录，然后迭代。

## 文件系统
这个实验的目的不是要你实现整个文件系统，而是需要实现关键部分，特别是
+ 在块缓存中读取块的内容，然后将其刷新回磁盘；
+ 分配磁盘块，映射文件偏移量至磁盘块；
+ 在IPC接口中实现读，写，打开文件;

因为你不需要单独实现整个文件系统，但是你需要对提供的代码与多个文件接口有足够的了解。

### 磁盘访问
JOS的操作系统中的文件系统需要访问磁盘，但是我们目前并没有在内核中实现任何磁盘访问的功能，我们实现IDE磁盘驱动，作为部分用户级文件系统环境，而不是像传统操作系统那样，将磁盘访问通过系统调用进行实现。但是我们任然需要稍微修改内核，使文件系统环境具有一定的特权。

只要我们通过轮询，可以很简单的在用户态下实现磁盘的访问，但是内核需要产生外设中断然后将其解析给正确的其他用户代码。

在X86处理器中，EFLAGS寄存器中的IOPL位决定了在保护模式下，是否运行产生特殊的设备IO指令，比如IN与OUT指令。由于我们需要的访问的IDE磁盘寄存器均位于X86的IO空间中，而不是MMAP空间中，为了允许文件系统访问寄存器我们只需要将IO特权授予即可。但是，IOPL位只提供了简单的“all or nothing”的方法来控制是否用户态可以访问IO空间，在我们的情况中，我们只想要文件系统代码可以访问，而不希望所有用户态都可以访问。

#### 练习一

`i386_init()`标识了文件系统代码，通过`env_create`函数，传递类型`ENV_TYPE_FS`，修改`env.c`中的`env_create`函数，使其给文件系统代码一个IO特权，但是并不给予其他用户态代码这样的特权。
确保你启动文件系统并不会导致一个General Protection fault， 你应该通过`make grade`中的"fs i/o"测试。

就是在该函数中加入类型判断：

```

//
// Allocates a new env with env_alloc, loads the named elf
// binary into it with load_icode, and sets its env_type.
// This function is ONLY called during kernel initialization,
// before running the first user-mode environment.
// The new env's parent ID is set to 0.
//
void env_create(uint8_t *binary, enum EnvType type)
{
	// LAB 3: Your code here.

	// If this is the file server (type == ENV_TYPE_FS) give it I/O privileges.
	// LAB 5: Your code here.
	
	int status;
	struct Env *pEnv;
	status = env_alloc(&pEnv, 0);
	if (status != 0)
		panic("env create : envalloc failed");
	
	load_icode(pEnv, binary);
	pEnv->env_type = type;
	if (type == ENV_TYPE_FS){
		pEnv->env_tf.tf_eflags |= FL_IOPL_MASK;
	}
}
```

#### 问题
1. 你需要通过其他方法确保IO特权设置被合理的设置与保存，当你随后从一个环境切换至另一个环境中，为什么?

ans:不需要，每个环境的状态，包括寄存器状态，被结构Env中的env_tf保存，当环境切换时，通过env_pop_tf函数保存当前状态并切换至其他状态，每个环境的状态操作系统均会切换。

#### 块缓存
在我们的文件系统中，在处理器的虚拟内存系统的帮助下，我们实现了一个简单的Buffer cache，代码在`fs/bc.c`中。

我们的文件系统最支持3GB的磁盘，我们保留了固定的3GB系统环境的地址空间，从0x1000 0000(DISKMAP)直到0x0D00 0000(DISKMAP + DISKMAX) 作为磁盘的内存映射版本，`fs/bc.c`中的`diskaddr`函数实现了磁盘块到虚拟地址的映射。

因为我们的文件系统有自己的地址空间，并独立与其他的代码，并且文件系统代码只需要实现的是文件访问。

当然，我们并不是将整个磁盘加载至内存，相反，我们实现了一种demand paging，我们只分配相应的块并通过page fault见对应的块加载至内存，这样我们可以避免整个磁盘文件在内存中。

#### 练习二

实现`bc_pgfault` `flush_back`函数在`fs/bc.c`中，`bc_pgfault`是一个page fault 处理程序，就像你之前lab写的copy-on-write fork，该处理程序是将页从磁盘中加载到内存，当你写代码的时候，你需要知道（1）`addr`有可能不是按照block边界对齐的（2）`ide_read`操作是以sector为单位，而不是block。
`flush_block`函数，应该将一个block写入磁盘，如果该block不在block缓存中，（也就是该页还没进行内存映射）或者该页不是脏写，该函数应该不做任何处理。我们需要通过虚拟内存硬件追踪是否一个磁盘块被修改过。为了知道该page是否被修改过，我们只需要查看`PTE_D`位，也就是脏位在`uvpt`目录中，在将block写回磁盘时，`flush_back`函数应该通过`sys_page_map`清除`PTE_D`位。
在你完成该练习之后，你应该通过make grade中的check_bc，check_super， check_bitmap测试。

`fs/fs.c`中的`fs_init`函数是一个最基本的使用block缓存的例子。在初始化化block缓存后，他简单将指向磁盘映射区域的指针存储到全局变量super中，在此之后，我们可以简单的从结构体super中读取，就想他们已经在内存里面一样，通过我们的页错误处理程序，我们可以按要求读取磁盘内容。

bc_pgfault()
```

// Fault any disk block that is read in to memory by
// loading it from disk.
static void
bc_pgfault(struct UTrapframe *utf)
{
	void *addr = (void *) utf->utf_fault_va;
	uint32_t blockno = ((uint32_t)addr - DISKMAP) / BLKSIZE;
	int r;

	// Check that the fault was within the block cache region
	if (addr < (void*)DISKMAP || addr >= (void*)(DISKMAP + DISKSIZE))
		panic("page fault in FS: eip %08x, va %08x, err %04x",
		      utf->utf_eip, addr, utf->utf_err);

	// Sanity check the block number.
	if (super && blockno >= super->s_nblocks)
		panic("reading non-existent block %08x\n", blockno);

	// Allocate a page in the disk map region, read the contents
	// of the block from the disk into that page.
	// Hint: first round addr to page boundary. fs/ide.c has code to read
	// the disk.
	//
	// LAB 5: you code here:
	uint32_t blkStart = ROUNDDOWN(addr, BLKSIZE);
	if ((r = sys_page_alloc(0, (void *)blkStart, (PTE_U |PTE_P | PTE_W))) < 0)
		panic("sys_page_alloc:%e\n", r);
	// now we had alloc page in va at blkStart
	if ((r = ide_read(blockno * BLKSECTS, blkStart, BLKSECTS)) < 0)
		panic("ide_read error:%e\n", r);
	// Clear the dirty bit for the disk block page since we just read the
	// block from disk
	if ((r = sys_page_map(0, addr, 0, addr, uvpt[PGNUM(addr)] & PTE_SYSCALL)) < 0)
		panic("in bc_pgfault, sys_page_map: %e", r);

	// Check that the block we read was allocated. (exercise for
	// the reader: why do we do this *after* reading the block
	// in?)
	if (bitmap && block_is_free(blockno))
		panic("reading free block %08x\n", blockno);
}
```

flush_block()

```

// Flush the contents of the block containing VA out to disk if
// necessary, then clear the PTE_D bit using sys_page_map.
// If the block is not in the block cache or is not dirty, does
// nothing.
// Hint: Use va_is_mapped, va_is_dirty, and ide_write.
// Hint: Use the PTE_SYSCALL constant when calling sys_page_map.
// Hint: Don't forget to round addr down.
void
flush_block(void *addr)
{
	uint32_t blockno = ((uint32_t)addr - DISKMAP) / BLKSIZE;

	if (addr < (void*)DISKMAP || addr >= (void*)(DISKMAP + DISKSIZE))
		panic("flush_block of bad va %08x", addr);

	// LAB 5: Your code here.
	// not dirty or not mapped do nothting
	void *blkStart = (void *)ROUNDDOWN(addr, BLKSIZE);
	if (!va_is_dirty(blkStart) || !va_is_mapped(blkStart))
		return;
	int r; // return value temp
	if ((r = ide_write(blockno * BLKSECTS, blkStart, BLKSECTS)) < 0)
		panic("ide_write error: %e\n", r);
	
	// reset dirty bits
	if ((r = sys_page_map(0, blkStart,0, blkStart, uvpt[PGNUM(blkStart)] & PTE_SYSCALL)) < 0)
		panic("flush_back, sys_page_map error %e\n", r);
	//panic("flush_block not implemented");
}
```


#### 块位图
在`fs_init`函数中设置了位图的指针，我们可以将为题看成打包的位数组，每位代表一个磁盘上的block，例如在`block_is_free`中，简单的检查是否给定的block在位图中是空的。

#### 练习三
以`free_block`为模型，实现`fs/fs.c`中的`alloc_block`，该函数应该找到一个空闲块，将其标记为已经使用，并返回其block编号。当你分配一个block，你应该马上通过`flush_back`函数刷新`bitmap block`至硬盘，维持文件系统的一致性。

你应该通过`alloc_block`测试，在make grade脚本中。


```

// Search the bitmap for a free block and allocate it.  When you
// allocate a block, immediately flush the changed bitmap block
// to disk.
//
// Return block number allocated on success,
// -E_NO_DISK if we are out of blocks.
//
// Hint: use free_block as an example for manipulating the bitmap.
int
alloc_block(void)
{
	// The bitmap consists of one or more blocks.  A single bitmap block
	// contains the in-use bits for BLKBITSIZE blocks.  There are
	// super->s_nblocks blocks in the disk altogether.
	uint32_t i;
	for(i = 0; i < super->s_nblocks; i ++){
		if (block_is_free(i)){
			bitmap[i / 32] &= ~(1 << (i % 32)); // 0 for used
			return i;
		}
	}
	// LAB 5: Your code here.
	//panic("alloc_block not implemented");
	return -E_NO_DISK;
}
```
#### 文件操作
目前为止，我们已经实现了很多基本功能在`fs/fs.c`，接下来需要解析与管理File结构体，扫描与管理目录文件，从在文件系统中，从节点到解析一个绝对路径，阅读`fs/fs.c`中的所有代码。

#### 练习四
实现`file_block_walk` 与 `file_get_block`。`file_block_walk`将一个文件中的block偏移量，映射至结构体File中的文件块或者非直接文件块（indirect block），与pgdir_walk特别相似。file_get_block进一步映射真实的磁盘块，按需分配真实的磁盘块。
你应该通过make grade脚本中的file_open file_get_block file_flush/file_truncated/file rewrite与testfile测试。


#### 文件系统的接口
现在我们的文件系统已经实现了必要的功能，我们必须让其可以被其他环境访问，由于其他环境不能直接调用文件系统代码，我们希望通过rpc访问文件系统，主要通过IPC将文件进行传递。
```
       Regular env           FS env
   +---------------+   +---------------+
   |      read     |   |   file_read   |
   |   (lib/fd.c)  |   |   (fs/fs.c)   |
...|.......|.......|...|.......^.......|...............
   |       v       |   |       |       | RPC mechanism
   |  devfile_read |   |  serve_read   |
   |  (lib/file.c) |   |  (fs/serv.c)  |
   |       |       |   |       ^       |
   |       v       |   |       |       |
   |     fsipc     |   |     serve     |
   |  (lib/file.c) |   |  (fs/serv.c)  |
   |       |       |   |       ^       |
   |       v       |   |       |       |
   |   ipc_send    |   |   ipc_recv    |
   |       |       |   |       ^       |
   +-------|-------+   +-------|-------+
           |                   |
           +-------------------+
```

在点线之下的是从普通环境向文件系统读请求的流程。一开始通过任意文件描述符号的函数read，通过函数devfile_read简单的解析合适的设备读取函数（这里的设备可以是管道等其他设备）。devfile_read函数和其他dev_file*函数，实现了文件操作系统的客户端，所以的函数的工作流程都大致相似，通过在请求结构体中绑定参数，调用fsipc发送一个IPC请求，解析并返回结果，fsipc函数简单的捕获发送请求的共同细节，然后接收回复。

文件系统的服务端代码在fs/serv.c中，serve函数的循环中，轮询接受IPC请求，解析请求并调用对应的函数，通过IPC返回对应的结果。在读取例子中，serve函数调用，通过解析IPC的细节，并最终调用file_read真实的读取文件。

JOS的IPC机制是，让一个用户态发送一个32bits的数字，可选的共享一个page。为了从客户端发送一个请求给服务器端，我们使用了一个32位的数字表示请求类型，然后在联合体Fsipc中存储这些参数，并通过IPC传递。在客户端这边，客户端总是共享fsipcbuf的page，在sever端，我们映射到来的请求至fsreq(0x0ffff000).

sever端也会通过IPC回应，我们使用32位的数字作为该函数的返回值，对于大部分的RPC而言，已经够了。FSREQ_READ与FSREQ_STAT也会返回数据，他们只是将数据写入客户端发送请求的页面，不需要通过IPC进行回应这个page，因为客户端已经将其共享。同样的FSREQ_OPEN与客户端共享了一个新的“FD page”，我们将会简短的返回一个文件描述符。

#### 练习五
实现`serve_read`in`fs/serv.c`
serve_read 的繁重工作将由 `fs/fs.c`中已经实现的 `file_read `完成（反过来，它只是对 `file_get_block` 的一堆调用）。 `serve_read`只需要提供用于文件读取的 RPC 接口。 查看 `serve_set_size `中的注释和代码，以大致了解服务器功能的结构。

```

// Read at most ipc->read.req_n bytes from the current seek position
// in ipc->read.req_fileid.  Return the bytes read from the file to
// the caller in ipc->readRet, then update the seek position.  Returns
// the number of bytes successfully read, or < 0 on error.
int
serve_read(envid_t envid, union Fsipc *ipc)
{
	struct Fsreq_read *req = &ipc->read;
	struct Fsret_read *ret = &ipc->readRet;

	if (debug)
		cprintf("serve_read %08x %08x %08x\n", envid, req->req_fileid, req->req_n);

	// Lab 5: Your code here:
	//  
	struct OpenFile *opfile;
	int r = openfile_lookup(envid, req->req_fileid, &opfile);
	if (r < 0)
		return r;
	// read file
	r = file_read(opfile->o_file, ret, req->req_n, opfile->o_fd->fd_offset);
	if (r > 0)
		opfile->o_fd->fd_offset += r;
	return r;
}
```
#### 练习六
Implement `serve_write` in `fs/serv.c` and `devfile_write`in `lib/file.c`

serve_write:
```

// Write req->req_n bytes from req->req_buf to req_fileid, starting at
// the current seek position, and update the seek position
// accordingly.  Extend the file if necessary.  Returns the number of
// bytes written, or < 0 on error.
int
serve_write(envid_t envid, struct Fsreq_write *req)
{
	if (debug)
		cprintf("serve_write %08x %08x %08x\n", envid, req->req_fileid, req->req_n);

	// LAB 5: Your code here.
	// 参照serve_read即可
	struct OpenFile *opfile;
	int r = openfile_lookup(envid, req->req_fileid, &opfile);
	if (r < 0)
		return r;
	size_t sz = MIN(req->req_n, PGSIZE - (sizeof(int) + sizeof(size_t)));
	r = file_write(opfile->o_file, req->req_buf, sz, opfile->o_fd->fd_offset);
	if (r > 0)
		opfile->o_fd->fd_offset += r;
	return r;
	//panic("serve_write not implemented");
}
```

`devfile_write`

```

// Write at most 'n' bytes from 'buf' to 'fd' at the current seek position.
//
// Returns:
//	 The number of bytes successfully written.
//	 < 0 on error.
static ssize_t
devfile_write(struct Fd *fd, const void *buf, size_t n)
{
	// Make an FSREQ_WRITE request to the file system server.  Be
	// careful: fsipcbuf.write.req_buf is only so large, but
	// remember that write is always allowed to write *fewer*
	// bytes than requested.
	// LAB 5: Your code here
	// 最大的n就是Fsipc.write中buf中的定义
	int maxSZ = PGSIZE - (sizeof(int) + sizeof(size_t));
	size_t sz = MIN(n, maxSZ);
	int r;
	// 参考devfile_read写定义
	fsipcbuf.write.req_fileid = fd->fd_file.id;
	fsipcbuf.write.req_n = sz;
	memmove(fsipcbuf.write.req_buf, buf, sz);
	// 最后在发送请求
	r = fsipc(FSREQ_WRITE, NULL);
	if (r < 0)
		return r;
	return sz;

	
	panic("devfile_write not implemented");
}
```
## Spwaning 进程
我已经给你写好了spawn代码(lib/spawn.c)，实现的功能是：
+ 创建一个新的环境
+ 从文件系统中加载一个程序镜像
+ 启动子进程运行该程序
+ 父进程独立的执行

spawn代码就像fork紧接着调用exec一样。

我们实现spawn而不是UNIX风格的exec是因为更容易脱离内核，在用户态实现。自己思考一下如果要你去实现一个用户态的exec。

#### 练习七
spawn依赖一个新的系统调用sys_env_set_trapframe去初始化新的环境，实现kern/syscall.c中的sys_env_set_trapframe，不要忘了在syscall的函数中解析并调用它。

通过运行user/spawnhello程序，该程序试图将/hello从文件系统中加载。
通过make grade测试你的代码。

```

// Set envid's trap frame to 'tf'.
// tf is modified to make sure that user environments always run at code
// protection level 3 (CPL 3), interrupts enabled, and IOPL of 0.
//
// Returns 0 on success, < 0 on error.  Errors are:
//	-E_BAD_ENV if environment envid doesn't currently exist,
//		or the caller doesn't have permission to change envid.
static int
sys_env_set_trapframe(envid_t envid, struct Trapframe *tf)
{
	// LAB 5: Your code here.
	// Remember to check whether the user has supplied us with a good
	// address!
	struct Env *e;
	int r;
	r = envid2env(envid, &e, 1);
	if (r < 0)
		return r;
	
    user_mem_assert(e, tf, sizeof(struct Trapframe), PTE_U);
    e->env_tf = *tf;
    e->env_tf.tf_cs |= 0x03; 
    e->env_tf.tf_eflags &=  (~FL_IOPL_MASK);
    e->env_tf.tf_eflags |= FL_IF;
    return 0;
	//panic("sys_env_set_trapframe not implemented");
}
```
### 在fork与spawn中共享库的状态

UNIX的文件描述符是一个通用的概念，包括管道，控制台I/O，在JOS中，每个设备类型都有其对应的结构体Dev，这个结构体中保存了对应设备的函数指针，lib/fd.c中在此基础上实现了类似UNIX的通用文件描述符接口，该文件中，大部分函数只是将操作分配给适当的struct Dev中的函数。

```
// Per-device-class file descriptor operations
struct Dev {
	int dev_id;
	const char *dev_name;
	ssize_t (*dev_read)(struct Fd *fd, void *buf, size_t len);
	ssize_t (*dev_write)(struct Fd *fd, const void *buf, size_t len);
	int (*dev_close)(struct Fd *fd);
	int (*dev_stat)(struct Fd *fd, struct Stat *stat);
	int (*dev_trunc)(struct Fd *fd, off_t length);
};
```

lib/fd.c也维护每个用户环境的地址空间中文件描述符号表区域，地址开始于FDTABLE(0xD000 0000)，这里保留了一个page的区域，每个环境最多也就是只有MAXFD（目前是32）个文件描述符。在任何情况下，文件描述符表所在的page当且仅当对应的文件描述符被使用的时候才能被映射，每个文件描述符也有一个可选的“数据page”其余，开始于FILEDATA，提供设备使用。

我们想要在fork与spawn中共享文件描述符号，但是文件描述符状态是在用户空间中的，在fork中，内存会被标记为COW，所以状态会被重复而不是shared（也就是说fork中的父子进程不可以共享同一个文件描述符，相应的文件与管道在fork之后也不会正常工作）在spawn中，内存会被丢弃，也没有相应的内存拷贝，所以spawn后的环境一开始是没有打开的文件描述符。

我们将更改fork以了解“库操作系统”使用的某些内存区域，并且应始终共享。 我们不会在某个地方硬编码区域列表，而是在页表条目中设置一个未使用的位（就像我们在fork中使用PTE_COW位一样）。

我们在inc/lib.h中定义了一个新的PTE_SHARE位。 该位是Intel和AMD手册中标记为“可供软件使用”的三个PTE位之一。 我们将建立一个约定，即如果页表项已设置此位，则应在fork和spawn中将PTE直接从父进程复制到子进程。 请注意，这与标记copy-on-write不同：如第一段所述，我们希望确保共享页面更新

#### 练习八
在lib/fork.c中修改duppage，如果页表实体的PTE_SHARE被设置，就只复制映射（应该使用PTE_SYSCALL而不是0xfff，来屏蔽页表条目中的相关位，0xfff也可以找到访问位与脏位）

相同的，实现在lib/spawn.c中的copy_shared_pages，它应该循环检测当前进程所有的页表目录，拷贝所有PTE_SHARE位被设置的页的映射。


使用make run-testpteshare去测试你的代码，你应该看见命令行打印“fork handle PTE_SHARE right”与"spawn handles PTE_SHARE right"。

使用make run-testfdsharing去测试文件描述符是否被合理共享，你应该看见命令行打印read in child succeeded"与"read in parent succeeded"。

`lib/fork.c`:
```

//
// Map our virtual page pn (address pn*PGSIZE) into the target envid
// at the same virtual address.  If the page is writable or copy-on-write,
// the new mapping must be created copy-on-write, and then our mapping must be
// marked copy-on-write as well.  (Exercise: Why do we need to mark ours
// copy-on-write again if it was already copy-on-write at the beginning of
// this function?)
//
// Returns: 0 on success, < 0 on error.
// It is also OK to panic on error.
//
static int
duppage(envid_t envid, unsigned pn)
{
	int r;

	// LAB 4: Your code here.
	void * va = (void *)(pn * PGSIZE);
	
	if (uvpt[pn] & PTE_SHARE){
		r = sys_page_map(thisenv->env_id, (void *)va, envid ,(void *)va, (uvpt[pn] & PTE_SYSCALL));
		if (r < 0)
			return r;
	}else if ( (uvpt[pn] & PTE_W) || (uvpt[pn] & PTE_COW)) {
		r = sys_page_map(0, va, envid, va, PTE_COW | PTE_P | PTE_U);
		if (r < 0)  {
			return r;
		}
		r = sys_page_map(0,va, 0,va, PTE_U | PTE_COW | PTE_P);
		if (r < 0) {
			return r;
		}
	} else  {
		r = sys_page_map(0,va,envid,va, PTE_P | PTE_U);
		if (r < 0) {
			return r;
		}
	}
	return 0;
	//panic("duppage not implemented");
}

```

`lib/spawn.c`:
```

// Copy the mappings for shared pages into the child address space.
static int
copy_shared_pages(envid_t child)
{
	// LAB 5: Your code here.
	uint32_t pgNum;
	int r;
	struct Env *e;
	for (pgNum = 0; pgNum < PGNUM(USTACKTOP); pgNum ++){
		if ((uvpd[pgNum >> 10] & PTE_P) && (uvpt[pgNum] & PTE_P) && (uvpt[pgNum] & PTE_SHARE)){
			if ((r = sys_page_map(0, (void *)(pgNum * PGSIZE), child, 
				(void *)(pgNum * PGSIZE), uvpt[pgNum] & PTE_SYSCALL)) < 0)
				return r;
		}
	}
	return 0;
}

```
### 键盘接口
为了让shell工作，我们需要能输入的方法，QEMU已经一直在显示我们的输入至CGA显示器与串口，但是目前为止，我们还仅仅在内核监视器中接受输入，在QEMU中，图形化界面键入的输入，显示为从键盘到JOS的输入，在控制台中键入的显示为串口上的字符，kern/console.c已经包含了lab1以来的内核监视器使用的键盘与串行驱动程序，现在需要把他们附加到系统其他部分。（也就是除了内核之外的程序应该可以读取键盘的输入。）

#### 练习九
在`kern/trap.c`中调用kbd_intr处理IRQ_OFFSET + IRQ_KB，调用serial_intr处理IRQ_OFFSET + IRQ_SERIAL

我们在`lib/console.c`中实现了控制台输入输出文件类型，`kbd_intr`与`serial_intr`填充一个缓存，然而控制台程序读取该缓存，并默认将其输出至标准输入输出。

通过make run-testkbd然后输入一行，系统会立马将你输入的字符进行输出，尝试在控制台与图形化窗口中输入，如果你有条件的话。


其实就是按照要求在trap.c中的trap_dispatch()按照注释加入对应的case
```
case (IRQ_OFFSET + IRQ_KBD):
   lapic_eoi();
   kbd_intr();
   break;
case (IRQ_OFFSET + IRQ_SERIAL):
   lapic_eoi();
   serial_intr();
   break;
```

### Shell
运行make run-icode或者make run-icode-nox，这将会运行你的内核然后启动user/icode。icode会执行init，该函数将控制台作为文件描述符号的0与1（标准输入与标准输出），然后接着spawn sh，shell，你应该可以运行一下的命令行。
```
   echo hello world | cat
	cat lorem |cat
	cat lorem |num
	cat lorem |num |num |num |num |num
	lsfd
```
用户库中的cprintf是直接在控制台上打印，而不是使用文件描述符。这比较容易调试，但是管道的其他程序而已，该方法是不能使用管道的。为了输出到一个特定的文件描述符，使用fprintf(1, "....", .....) or printf(".....", ....)，例如user/lsfd.c。

#### 练习十

shell现在不支持IO重定向，但是运行run < script 不用手打所有命令，而是使用脚本的好方式，在user/sh.c中增加<的IO重定向。
通过sh < script 测试你的代码是否正确。
运行 make run-testshell去测试你的shell，testshell简单的将fs/testshell.sh所有的命令送给shel。然后检查输出是否与fs/testshell.key匹配。


按照注释的要求来即可，简单的打开一个文件，将该文件描述符与0（stdin）关联，然后关掉新的文件描述符。
```
case '<':	// Input redirection
   // Grab the filename from the argument list
   if (gettoken(0, &t) != 'w') {
      cprintf("syntax error: < not followed by word\n");
      exit();
   }
   // Open 't' for reading as file descriptor 0
   // (which environments use as standard input).
   // We can't open a file onto a particular descriptor,
   // so open the file as 'fd',
   // then check whether 'fd' is 0.
   // If not, dup 'fd' onto file descriptor 0,
   // then close the original 'fd'.

   // LAB 5: Your code here.
   // open t
   fd = open(t, O_RDONLY);
   if (fd < 0){
      cprintf("file %s open failed: %e\n", t, fd);
      exit();
   }
   // fd not 0
   if (fd != 0){
      // dup and close old fd
      dup(fd, 0);
      close(fd);
   }
   //panic("< redirection not implemented");
   break;
```