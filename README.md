# oc-localtar
A script that works for the Minecraft mod **Opencomputers**, that download tarball archive and store it in local in-game tape  
By 6C-C6  

[[English]](#English)  [[中文]](#中文)  

---

### English

This program will download packed files in ```.tar.gz``` or other gzip packs, and store them into in-game tape from Computronics.  
Currently it only supports file with an unpacked size smaller than tape size.  

In default config, the function data.inflate in Opencomputers has an input limit of 1MiB, so here we break this limit, by split the deflate stream into parts, and reassemble them into proper zlib deflate streams.  
For normal github archive files, this program can run in devices with 4MiB RAM inside OpenOS, which can be achieved by installing four T3.5 RAM in a T3 server.  

Usage: change variable 'url' to the target url in ```localtar.lua```, and run it with ```lua localtar.lua```.  
In case a memory overflow happens, you can change the value BUFFER_RAISE in ```localtar.lua``` and value MAX_BUFFER in ```download2buffer.lua```, refrencing on its comments.  

---

### 中文

这个程序会下载```.tar.gz```形式的压缩包或其它gzip压缩包，并存储在Computronics的磁带中。  
目前仅支持解压后大小小于磁带容量的文件。  

默认配置下Opencomputers（oc）的inflate函数具有最大1MiB的输入限制，因此通过解析deflate流并分割重组的方式突破该限制。  
对于一般的github archive文件，它可在4MiB内存的oc设备中运行而不会爆内存，这可以通过在T3服务器中安装4条T3.5内存达到。  

使用方法：修改```localtar.lua```中的url变量，并通过```lua localtar.lua```运行。  
若发生内存溢出，可更改```localtar.lua```中BUFFER_RAISE及```download2buffer.lua```中MAX_BUFFER的大小规避，参考其注释。  
