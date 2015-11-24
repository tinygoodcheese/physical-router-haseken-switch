#プログラムの説明
作成した![プログラム](https://github.com/handai-trema/simple_router-team_alpha/blob/master/lib/simple_router13.rb)について説明をする。
テーブル構成は以下のテーブル構成とした．![テーブル構成](https://github.com/handai-trema/simple_router-team_alpha/blob/master/table.png)
実装すべき動作を考えるため，host1からhost2にpingを送る場合を考えると以下のようになる．

1. host1がルータにARPリクエストを送る
2. ルータがhost1からのARPリクエストに対してARPリプライを送る
3. host1がルータからのARPリプライを元にルータにパケットを送る
4. ルータはhost2の宛先MACアドレスを保持していないため、host1からhost2へのパケットを、ARP未解決パケットとしてコントローラに貯めておく
5. ルータがhost2にARPリクエストを送る
6. host2がルータからのARPリクエストに対してARPリプライを送る
7. ルータがhost2からのARPレスポンスを元に、コントローラに貯めていたパケットをhost2に送る

以上をふまえて，まずはじめにswitch_readyで追加しておくべき
フローエントリを述べる．

##Protocol Classifierテーブル

Protocol Classifierテーブルがパケットの種類(ARPかIPv4か)によって
ARP RESPONDERとRouting Tableのどちらのテーブルに移動するかを
判別する．
そのため，Classifierテーブルに次のようにして，フローエントリをはじめに追加する．
```
    send_flow_mod_add(
      dpid,
      table_id: CLASSIFIER_TABLE_ID,
      idle_timeout: 0,
      priority: 0,
      match: Match.new(
	ether_type: ETHER_TYPE_ARP
      ),
      instructions: GotoTable.new(ARP_RESPONDER_TABLE_ID)
    )

    send_flow_mod_add(
      dpid,
      table_id: CLASSIFIER_TABLE_ID,
      idle_timeout: 0,
      priority: 0,
      match: Match.new(ether_type: ETHER_TYPE_IPv4),
      instructions: GotoTable.new(ROUTING_TABLE_ID)
    )
```

##ARP RESPONDERテーブル

ARP RESPONDERテーブルではARPパケットに関する処理を行う．
ARPリクエストが発生した場合，OpenFlow1.0版ルータではpacket inが発生して
処理を行っていたが，ルータは自身のポートとそれに対応するMACアドレスを知っているためpacket inを起こさなくても，arp requestを返すことができる．
ルータ自身の情報は次のようにして得る事ができる．
```
    interface_hash = Configuration::INTERFACES
```
Configuration::INTERFACESはハッシュ構造になっており，ルータ内の
ポートとそれに対応するMACアドレスなどがそれぞれ入っている．
ARPリクエストが来たとき，そのリクエストをARPリプライに変え，
ARPリクエストの送信元MACアドレスは次の送信先MACアドレスになる．
また，ARPリプライの送信元MACアドレス(ルータのポートに対応するMACアドレス)，
IPアドレス，なども同時に設定する必要がある．送信先のポート番号は
同じポートに出すので，reg1に退避させておく．
これらのアクションと，パケットの送信を行うEGRESSテーブルへの移動を
次のようにセットする．
```
    ip_address = IPv4Address.new(each.fetch(:ip_address))
    actions = [
           NiciraRegMove.new(from: :source_mac_address,
                             to: :destination_mac_address),
	   SetSourceMacAddress.new(each.fetch(:mac_address)),
	   SetArpOperation.new(Arp::Reply::OPERATION),
	   NiciraRegMove.new(from: :arp_sender_hardware_address,to: :arp_target_hardware_address),
          NiciraRegMove.new(from: :arp_sender_protocol_address,to: :arp_target_protocol_address),
           SetArpSenderHardwareAddress.new(each.fetch(:mac_address)),
	   SetArpSenderProtocolAddress.new(ip_address),
           NiciraRegLoad.new(value, :in_port),
           NiciraRegLoad.new(each.fetch(:port), :reg1)
	]

    send_flow_mod_add(
       dpid,
       table_id: ARP_RESPONDER_TABLE_ID,
       idle_timeout: 0,
       priority: 0,
       match: Match.new(
              ether_type: ETHER_TYPE_ARP,
              arp_operation: Arp::Request::OPERATION,
              arp_target_protocol_address: ip_address,
              in_port: each.fetch(:port)),
       instructions: [Apply.new(actions),GotoTable.new(EGRESS_TABLE_ID)])
```

ルータが送ったARPリクエストに対するARPリプライが来たときは
コントローラに問い合わせるため次のフローエントリを追加しておく．
```
    send_flow_mod_add(
       dpid,
       table_id: ARP_RESPONDER_TABLE_ID,
       idle_timeout: 0,
       priority: 0,
       match: Match.new(
              ether_type: ETHER_TYPE_ARP,
              arp_operation: Arp::Reply::OPERATION,
              arp_target_protocol_address: ip_address,
              in_port: each.fetch(:port)),
       instructions: Apply.new(SendOutPort.new(:controller))
     )
```

##Routingテーブル
Routingテーブルではipv4パケットの送信先アドレスを
保持するため，reg0に送信先アドレスを退避させる．
```
    actions = [NiciraRegMove.new(from: :ipv4_destination_address,to: :reg0)]
    send_flow_mod_add(
       dpid,
       table_id: ROUTING_TABLE_ID,
       idle_timeout: 0,
       priority: 10,
       match: Match.new(
              ether_type: ETHER_TYPE_IPv4,
              ipv4_destination_address: ip_address_mask,
              ipv4_destination_address_mask: default_mask2),
       instructions: [Apply.new(actions),GotoTable.new(INTERFACE_LOOKUP_TABLE_ID)]
     ) 
```

##INTERFACE LOOKUPテーブル
次のINTERFACE LOOKUPテーブルでは
送信するためのポート番号をreg1に退避しておき，送信元のMACアドレスを
ルータのものに書き換える．そして次のARP LOOKUPテーブルに移動するため．
次のようにフローエントリを追加する．
```
    actions = [NiciraRegLoad.new(each.fetch(:port),:reg1),
               SetSourceMacAddress.new(each.fetch(:mac_address))]
    send_flow_mod_add(
       dpid,
       table_id: INTERFACE_LOOKUP_TABLE_ID,
       idle_timeout: 0,
       priority: 0,
       match: Match.new(
              reg0: ip_address_mask.to_i,
              reg0_mask: default_mask2.to_i),
       instructions: [Apply.new(actions),GotoTable.new(ARP_LOOKUP_TABLE_ID)]
     ) 

```
##ARP LOOKUPテーブル
ARP LOOKUPテーブルでは，コントローラにパケットをどのように扱うか
問い合わせるためpacket inを生じさせるため次のようにして
フローエントリを追加する．
```
    send_flow_mod_add(
      dpid,
      table_id: ARP_LOOKUP_TABLE_ID,
      idle_timeout: 0,
      priority: 1,
      match: Match.new,
      instructions: Apply.new(SendOutPort.new(:controller)),
    )
```

##EGRESSテーブル
EGRESSテーブルは，最終的にパケットを送信するテーブルになっている．
送信するためのポートはreg1に退避されているのでその宛先宛に
送信するため，次のようにしてフローエントリを追加する．
```
    send_flow_mod_add(
      dpid,
      table_id: EGRESS_TABLE_ID,
      idle_timeout: 0,
      priority: 0,
      match: Match.new,
      instructions: Apply.new(NiciraSendOutPort.new(:reg1)),
    )
```

以上がswitch readyで追加すべきフローエントリである．
もう1つ最初に追加すべきフローエントリがあるが，それは
次の実行時に追加されるフローエントリの中で述べる．


##実行時に追加されるフローエントリ

実行時に追加されるフローエントリについて述べる．
packet inはARPリプライとIPv4パケットに対して生じる．
ルータが送ったARPリクエストに対するARPリプライが返ってきた
とき，宛先MACアドレスが解決できたので，コントローラに溜まっている
パケットを送信する．また同時に，今後その宛先IPアドレス(最初に述べた例でいうhost2のIPアドレス)に対するパケットはコントローラに問い合わせることなく(packet inを起こさず)，
送信してほしいのでそのためのフローエントリを追加する．
つまりARPリプライの送信元MACアドレスはパケットの送信先MACアドレスとなり，
送信先ポートもARPリプライパケットがきたポートをそのまま用いれば良い．
そしてパケットを送信するためにEGRESSテーブルに移動する．
よって次のようにしてフローエントリをARP LOOKUPテーブルに追加する．
```
    action = [NiciraRegLoad.new(message.source_mac.to_i,:destination_mac_address),
               NiciraRegLoad.new(message.in_port, :reg1)]
    send_flow_mod_add(
      dpid,
      table_id: ARP_LOOKUP_TABLE_ID,
      idle_timeout: 0,
      priority: 2,
      match: Match.new(
     ether_type: ETHER_TYPE_IPv4,
     ipv4_destination_address: message.sender_protocol_address),
      instructions:[Apply.new(action),GotoTable.new(EGRESS_TABLE_ID)]
    )
```
以上の実装でhost間のpingを実装することができた．
しかしこのままではルータに対するpingが実装できていない．
現在のままでルータに対してpingを送ったときを考えると，
Classifierテーブル，Routingテーブル，Interface lookupテーブルを経て
ARP lookupテーブルでpacket inが発生し，packet_in_ipv4が呼び出される．
ルータに対するpingの場合，以下のpacket_in_icmpv4_echo_requestが呼び出される．
OpenFlow1.0版のルータではarp未解決の場合，パケットを後で送信しているが，
送信元の情報は届いたパケットが分かっているので，そのままパケットを送り返せばよいので
packet_in_icmpv4_echo_requestの中でそのままsend_packet_outすれば良い．


```
  def packet_in_ipv4(dpid, message)
    if forward?(message)
      forward(dpid, message)
    elsif message.ip_protocol == 1
      icmp = Icmp.read(message.raw_data)
      packet_in_icmpv4_echo_request(dpid, message) if icmp.icmp_type == 8
    else
      logger.debug "Dropping unsupported IPv4 packet: #{message.data}"
    end
  end

  # rubocop:disable MethodLength
  def packet_in_icmpv4_echo_request(dpid, message)
    icmp_request = Icmp.read(message.raw_data)
    interface = @interfaces.find_by(port_number: message.in_port)
      send_packet_out(dpid,
                      raw_data: create_icmp_reply(icmp_request).to_binary,
                      actions: SendOutPort.new(message.in_port))

    end
  end

```

しかしここで気をつけなければならないのが，これまでのフローエントリのままだと
INTERFACE LOOKUPテーブルに追加された以下のフローエントリによって，
メッセージの送信元MACアドレスがルータ自身のものに書き換えられてしまっているため，
送信元のホストにパケットを送り返すことができない．

```
    actions = [NiciraRegLoad.new(each.fetch(:port),:reg1),
               SetSourceMacAddress.new(each.fetch(:mac_address))]
    send_flow_mod_add(
       dpid,
       table_id: INTERFACE_LOOKUP_TABLE_ID,
       idle_timeout: 0,
       priority: 0,
       match: Match.new(
              reg0: ip_address_mask.to_i,
              reg0_mask: default_mask2.to_i),
       instructions: [Apply.new(actions),GotoTable.new(ARP_LOOKUP_TABLE_ID)]
     ) 
```

そこでROUTINGテーブルで，もしルータ宛のパケットの場合，INTERFACE LOOKUPテーブルに
移動させず，コントローラに直接渡せば良い．
そのためswitch_readyで次のフローエントリも追加しておく．

```
    send_flow_mod_add(
       dpid,
       table_id: ROUTING_TABLE_ID,
       idle_timeout: 0,
       priority: 40024,
       match: Match.new(
              ether_type: ETHER_TYPE_IPv4,
              ipv4_destination_address: ip_address),
       instructions: [Apply.new(SendOutPort.new(:controller))]
     )     
```

#実行結果
まず実行開始時のフローエントリを示す．
```
$ sudo ovs-ofctl dump-flows br0x1 --protocols=OpenFlow13
OFPST_FLOW reply (OF1.3) (xid=0x2):
 cookie=0x0, duration=8.040s, table=0, n_packets=0, n_bytes=0, priority=0,arp actions=goto_table:2
 cookie=0x0, duration=8.003s, table=0, n_packets=0, n_bytes=0, priority=0,ip actions=goto_table:3
 cookie=0x0, duration=8.003s, table=2, n_packets=0, n_bytes=0, priority=0,arp,in_port=1,arp_tpa=192.168.1.1,arp_op=1 actions=move:NXM_OF_ETH_SRC[]->NXM_OF_ETH_DST[],set_field:00:00:00:01:00:01->eth_src,set_field:2->arp_op,move:NXM_NX_ARP_SHA[]->NXM_NX_ARP_THA[],move:NXM_OF_ARP_SPA[]->NXM_OF_ARP_TPA[],set_field:00:00:00:01:00:01->arp_sha,set_field:192.168.1.1->arp_spa,load:0xffff->OXM_OF_IN_PORT[],load:0x1->NXM_NX_REG1[],goto_table:6
 cookie=0x0, duration=8.003s, table=2, n_packets=0, n_bytes=0, priority=0,arp,in_port=1,arp_tpa=192.168.1.1,arp_op=2 actions=CONTROLLER:65535
 cookie=0x0, duration=7.998s, table=2, n_packets=0, n_bytes=0, priority=0,arp,in_port=2,arp_tpa=192.168.2.1,arp_op=1 actions=move:NXM_OF_ETH_SRC[]->NXM_OF_ETH_DST[],set_field:00:00:00:01:00:02->eth_src,set_field:2->arp_op,move:NXM_NX_ARP_SHA[]->NXM_NX_ARP_THA[],move:NXM_OF_ARP_SPA[]->NXM_OF_ARP_TPA[],set_field:00:00:00:01:00:02->arp_sha,set_field:192.168.2.1->arp_spa,load:0xffff->OXM_OF_IN_PORT[],load:0x2->NXM_NX_REG1[],goto_table:6
 cookie=0x0, duration=7.994s, table=2, n_packets=0, n_bytes=0, priority=0,arp,in_port=2,arp_tpa=192.168.2.1,arp_op=2 actions=CONTROLLER:65535
 cookie=0x0, duration=8.003s, table=2, n_packets=0, n_bytes=0, priority=0,arp,reg1=0x1 actions=set_field:00:00:00:01:00:01->eth_src,set_field:00:00:00:01:00:01->arp_sha,set_field:192.168.1.1->arp_spa,goto_table:6
 cookie=0x0, duration=7.988s, table=2, n_packets=0, n_bytes=0, priority=0,arp,reg1=0x2 actions=set_field:00:00:00:01:00:02->eth_src,set_field:00:00:00:01:00:02->arp_sha,set_field:192.168.2.1->arp_spa,goto_table:6
 cookie=0x0, duration=7.977s, table=3, n_packets=0, n_bytes=0, priority=40024,ip,nw_dst=192.168.1.1 actions=CONTROLLER:65535
 cookie=0x0, duration=7.971s, table=3, n_packets=0, n_bytes=0, priority=40024,ip,nw_dst=192.168.2.1 actions=CONTROLLER:65535
 cookie=0x0, duration=7.981s, table=3, n_packets=0, n_bytes=0, priority=10,ip,nw_dst=192.168.1.0/24 actions=move:NXM_OF_IP_DST[]->NXM_NX_REG0[],goto_table:4
 cookie=0x0, duration=7.974s, table=3, n_packets=0, n_bytes=0, priority=10,ip,nw_dst=192.168.2.0/24 actions=move:NXM_OF_IP_DST[]->NXM_NX_REG0[],goto_table:4
 cookie=0x0, duration=7.967s, table=4, n_packets=0, n_bytes=0, priority=0,reg0=0xc0a80100/0xffffff00 actions=load:0x1->NXM_NX_REG1[],set_field:00:00:00:01:00:01->eth_src,goto_table:5
 cookie=0x0, duration=7.964s, table=4, n_packets=0, n_bytes=0, priority=0,reg0=0xc0a80200/0xffffff00 actions=load:0x2->NXM_NX_REG1[],set_field:00:00:00:01:00:02->eth_src,goto_table:5
 cookie=0x0, duration=7.961s, table=5, n_packets=0, n_bytes=0, priority=1 actions=CONTROLLER:65535
 cookie=0x0, duration=7.959s, table=6, n_packets=0, n_bytes=0, priority=0 actions=output:NXM_NX_REG1[]
```
プログラムの説明で示した，switch_readyで追加すべきフローエントリが追加
されていることが確認できる．
まずhost1からhost2にpingを送る．
```
$ ./bin/trema netns host1
root@ensyuu2-VirtualBox:~/class/simple_router-team_alpha# ping 192.168.2.2
PING 192.168.2.2 (192.168.2.2) 56(84) bytes of data.
64 bytes from 192.168.2.2: icmp_seq=1 ttl=64 time=100 ms
64 bytes from 192.168.2.2: icmp_seq=2 ttl=64 time=0.490 ms
64 bytes from 192.168.2.2: icmp_seq=3 ttl=64 time=0.064 ms
64 bytes from 192.168.2.2: icmp_seq=4 ttl=64 time=0.043 ms
64 bytes from 192.168.2.2: icmp_seq=5 ttl=64 time=0.060 ms
64 bytes from 192.168.2.2: icmp_seq=6 ttl=64 time=0.071 ms
64 bytes from 192.168.2.2: icmp_seq=7 ttl=64 time=0.061 ms
64 bytes from 192.168.2.2: icmp_seq=8 ttl=64 time=0.065 ms
```
正しくpingが届いていることが分かった．続いて逆にhost2からhost1にも
pingを送信する．
```
$ ./bin/trema netns host2
root@ensyuu2-VirtualBox:~/class/simple_router-team_alpha# ping 192.168.1.2
PING 192.168.1.2 (192.168.1.2) 56(84) bytes of data.
64 bytes from 192.168.1.2: icmp_seq=1 ttl=64 time=0.247 ms
64 bytes from 192.168.1.2: icmp_seq=2 ttl=64 time=0.047 ms
64 bytes from 192.168.1.2: icmp_seq=3 ttl=64 time=0.045 ms
64 bytes from 192.168.1.2: icmp_seq=4 ttl=64 time=0.067 ms
64 bytes from 192.168.1.2: icmp_seq=5 ttl=64 time=0.051 ms
64 bytes from 192.168.1.2: icmp_seq=6 ttl=64 time=0.052 ms
```
こちらも正しく届いていることが分かった．ここでARP LOOKUPテーブルのフローテーブルに
ARP未解決だったパケットを今後は同じ宛先に届ける為のフローエントリが追加されているか
確認する．
```
$ sudo ovs-ofctl dump-flows br0x1 --protocols=OpenFlow13
OFPST_FLOW reply (OF1.3) (xid=0x2):
-(中略)-
cookie=0x0, duration=179.715s, table=5, n_packets=13, n_bytes=1274, priority=2,ip,nw_dst=192.168.2.2 actions=load:0xfe1860a1cc0a->NXM_OF_ETH_DST[],load:0x2->NXM_NX_REG1[],goto_table:6
 cookie=0x0, duration=179.664s, table=5, n_packets=13, n_bytes=1274, priority=2,ip,nw_dst=192.168.1.2 actions=load:0x67e908b719e->NXM_OF_ETH_DST[],load:0x1->NXM_NX_REG1[],goto_table:6
 -(後略)-
```
正しくフローエントリが追加されていることが確認できた．
最後にホストからルータへのpingが届くかを確認する．
```
$ ./bin/trema netns host1
root@ensyuu2-VirtualBox:~/class/simple_router-team_alpha# ping 192.168.1.1
PING 192.168.1.1 (192.168.1.1) 56(84) bytes of data.
64 bytes from 192.168.1.1: icmp_seq=1 ttl=128 time=5.88 ms
64 bytes from 192.168.1.1: icmp_seq=2 ttl=128 time=7.79 ms
64 bytes from 192.168.1.1: icmp_seq=3 ttl=128 time=7.35 ms
64 bytes from 192.168.1.1: icmp_seq=4 ttl=128 time=6.45 ms
64 bytes from 192.168.1.1: icmp_seq=5 ttl=128 time=14.5 ms
```

以上のようにルータへのpingも正しく届いていることが分かった．
これらの結果から要求された仕様のOpenFlow1.3版ルータの実装ができていることが
確認できた．

#謝辞
この課題におきまして、東野研究室の山田くんに多大な助言をいただきましたことを
ここに感謝の意を表します。
