# SDRAM CTRL

## 简介

本设计是一块SDRAM控制器，其中有两个文件，`src`文件是完全体，支持AXI4 32/64 bit的总线协议，并且支持

全部颗粒的SDRAM可以通过配置相应的SDRAM组织结构和电汽特性生成相应的控制器。但是很遗憾目前还有BUG

没有完全跑通全部颗粒，并且没有进行大量测试，所以再此情况下，在此基础上精简出了一个精简版的控制器`sec_se`

该控制器目前支持AXI4 32 bit总线 以及镁光`mt48lc32m16a2` 64MByte的SDRAM颗粒。

## 验证

可以通过VCS或者ModelSim进行验证其中`tb_top.v`为testbench，`mt48lc32m16a2.v`为颗粒模型，其余为源文件。

## 仿真截图
![Vivado](/pic/vivado.png "viavdo")
![modulesim](/pic/modlesim.png "modulesim")
