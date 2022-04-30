# HomeWork2:Shell

## 目录

### 实验之前的准备
首先下载[6.828Shell](https://pdos.csail.mit.edu/6.828/2018/homework/sh.c)并阅读代码，Shell的主要功能是解析命令与执行命令，本作业中的Shell只实现了几个最简单的命令如下：
```
ls > y
cat < y | sort | uniq | wc > y1
cat y1
rm y1
ls |  sort | uniq | wc
rm y
```
将上面的代码创建脚本't.sh'，首先通过命令编译sh.c
```
gcc sh.c
```
得到文件a.out， 并用系统本身的重定位将t.sh通过sh.c中所定义的shell执行，当然会有问题：
```
fy@FY-Labtop:~/Code$ ./a.out<t.sh
redir not implemented
exec not implemented
pipe not implemented
exec not implemented
exec not implemented
pipe not implemented
exec not implemented
```


### Executing simple commands
代码中的解析器已经提供了一个函数`execcmd`，仅需要在函数'runcmd'中补充case ' '就可以，提示你参考execv的使用。

因为我使用的是ubuntu 18.04，ls就放在/bin目录下，sort、wc、uniq放在/usr/bin目录下，为了保证每次输入都按优先级去找当前路径、/bin、/usr/bin，先采用系统调用`access`确定指令是否可行，不行就继续找，如果都不行就报错。代码如下：
```
case ' ':
    ecmd = (struct execcmd*)cmd;
    if(ecmd->argv[0] == 0)
      _exit(0);
    
    // Your code here ...
    if (access(ecmd->argv[0], F_OK) == 0){
      execv(ecmd->argv[0], ecmd->argv);
      exit(EXIT_SUCCESS);
      eflag = 1;
    }else{
      char path[2][256] = {"/bin/", "/usr/bin/"};
      for (int i = 0; i < 2; i ++){
        strcat(path[i], ecmd->argv[0]);
        if(access(path[i], F_OK) == 0){
          execv(path[i], ecmd->argv);
          exit(EXIT_SUCCESS);
          eflag = 1;
        }
        
      }
    }
    if (!eflag)
      fprintf(stderr, "excv is not implemented\n");
    
    break;
```



### I/O redirect
实现I/O的重定位，使得你可以：
```
echo "6.828 is cool" > x.txt
cat < x.txt
```
解析器已经识别了'<'或者'>'并且建立了一个redircmd，你只需要在runcmd中补全这部分代码，提示使用close或者open函数。

解答：这里的IO重定位与后面的管道，都涉及到文件描述符（file descript），这里总结一下，文件描述符数据类型是一个整型数字，是对一个文件信息的抽象，这里的文件信息包括标准输入输出与错误信息，shell运行的进程默认会有已经三个文件描述符（0：stdin,1:stdout 2:stderr），值得注意的是，每次创建文件描述符，当前进程可用的**最小数字**。

回到IO重定位问题上来，IO重定位是原本由标准输入输出，转由文件输入输出。实现原理就是关闭对应的标准输入\输出的fd，再打开对应的文件，该文件描述符自动填充关闭的标准输入\输出的fd，由此达到重定向的目的。

代码如下：
```
  case '>':
  case '<':
    rcmd = (struct redircmd*)cmd;
    //fprintf(stderr, "redir not implemented\n");
    // Your code here ...
    if (close(rcmd->fd) < 0){
      fprintf(stderr, "close stdout or stdin error\n");
      exit(0);
    }
      
    if(open(rcmd->file, rcmd->flags) < 0){
      fprintf(stderr, "file:%s is not exist\n", rcmd->file);
      exit(0);
    }
    rcmd->type = ' ';
    runcmd(rcmd->cmd);
    break;
```



### Implement pipes
实现管道：
同样已经经过字符串解析了，通过pipecmd传递，需要在runcmd中将其补全，提示使用fork dup close pipe等系统调用。

管道与IO重定向的区别，在于管道是进程之间的通信，IO重定向是进程与文件的通信。
实现原理参考了[linux manpage](https://man7.org/linux/man-pages/man2/pipe.2.html)，主要的流程，通过fork创建两个进程，在命令行左边的先创建，右边的后创建，首先需要通过pipe系统调用创建两个匿名管道也就是拥有两个文件描述符，pipe[0]是read pipe也就是输入端管道，pipe[1]是write end of pipe输出端的管道，在根据需要，关闭对应的进程的标准输入\输出与对应的输入输出管道，在通过dup系统调用，将进程的标准输入\输出与管道进行关联。


代码如下:
```
  case '<':
    rcmd = (struct redircmd*)cmd;
    //fprintf(stderr, "redir not implemented\n");
    // Your code here ...
    if (close(rcmd->fd) < 0){
      fprintf(stderr, "close stdout or stdin error\n");
      exit(0);
    }
      
    if(open(rcmd->file, rcmd->flags) < 0){
      fprintf(stderr, "file:%s is not exist\n", rcmd->file);
      exit(0);
    }
    rcmd->type = ' ';
    runcmd(rcmd->cmd);
    break;

  case '|':
    pcmd = (struct pipecmd*)cmd;
    //fprintf(stderr, "pipe not implemented\n");
    // Your code here ...
    if (pipe(p) == -1){
      // 0 read
      perror("pipe");
      exit(EXIT_FAILURE);
    }

    if (fork1() == 0){
      // child write process
      close(1);
      dup(p[1]);
      close(p[0]);// close read pipe after dup it
      close(p[1]); // close write pipe
      runcmd(pcmd->left);
    }
    wait(&r);
    if (fork1() == 0){
      //parents write process
      close(0);
      dup(p[0]);
      close(p[0]);
      close(p[1]);
      runcmd(pcmd->right);
    }
    close(p[0]);
    close(p[1]);
    wait(&r);
    break;
```

