# 情報科学演習２最終課題 成果物利用方法 
  成果物のアップロード先及び、情報科学演習２の最終成果発表で行った__デモの再現方法__を以下に示す。

## 成果物一覧

* __仮想マシン1__ : ensyuuVB1.ova
  - ホスト、Openflow スイッチ、コントローラとして機能
* __仮想マシン2__ : router.ova
  - 物理ルータとして機能

## アップロード先
  長谷川研究室の Web サーバを利用した  
  URL : http://www-imase.ist.osaka-u.ac.jp/ensyu2_vm.zip 

## デモの再現方法

### 物理構成 
  ※ ポスターの「テスト環境：ハードウェア構成」参照
  * インタフェースを２つ以上持つ物理マシンを２台用意し、１台には仮想マシン1、もう１台には仮想マシン2を導入
  * 両方の物理マシンのインタフェース２つを利用して、両物理マシン間がLANケーブル２本で接続されている環境を構築
  * VMファイルのインタフェースと Virtual Box ホストマシンのインタフェースをブリッジ接続しておく


### 仮想マシン初期設定

#### 仮想マシン1 
  ※ ~/Documents/physical-router-haseken-switch 配下が使用するOpenflowコントローラのソースコードである
  * __trema.conf__  
   - 変更無し
  * __simple_router.conf__  
   - port:3 を持つエントリ２つの mac_address を対応する接続先(仮想マシン2を導入したマシンの)インタフェースの MAC アドレスに書き換える
```
{dpid: 0x1,
port: 3,
mac_address: <192.168.3.2を持つインタフェースのMAC アドレス>
…
}
…
{dpid: 0x2,
port: 3,
mac_address: <192.168.4.2を持つインタフェースのMACアドレス>
…
}
```

  * __users.conf__  
   - 変更無し

#### 仮想マシン2
 * arp テーブルの書き換え
  - 対応する接続先(仮想マシン1を導入したマシンの)インタフェースの MAC アドレスを arp テーブルに追加
```
sudo arp -s 192.168.3.1 <192.168.3.1を持つインタフェースの MAC アドレス>  
sudo arp -s 192.168.4.1 <192.168.4.1を持つインタフェースの MAC アドレス>
```


### 動作確認
#### 仮想マシン1
 * OpenVswitch、Openflowコントローラ、ホストの起動  
  ``` 
  bin/trema run lib/simple_router.rb -c trema.conf  
  ```
 * 仮想マシンのインタフェースとOpenVswitchのインタフェースをブリッジ接続  
  ```
  ./add_port.sh
  ```
 * ターミナルを４つ起動し、それぞれのホスト(host1,host2,host3,host4)のコマンドラインを開く  
  ```
  ./bin/trema netns host1
  ```
 * host3, host4 について、tcpdumpを行う  
  ```
  ./tcpdump.sh
  ```
 * host1より、宛先IPアドレス(192.168.2.1)を指定しpingを送信し、host3のみにpingが到着したことを確認  
  ```
  ping -c10 192.168.2.1
  ```


