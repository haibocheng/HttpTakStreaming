/**
 * Flex swc library for Http Tak Streaming.
 * 
 * Copyright 2012 - 2012 by Taktod. All rights reserved.
 */
package com.ttProject.net
{
	import com.ttProject.core.FlvStream;
	import com.ttProject.events.HtsEvent;
	import com.ttProject.logger.Logger;
	import com.ttProject.logger.LoggerFactory;
	
	import flash.events.Event;
	import flash.events.IOErrorEvent;
	import flash.events.NetStatusEvent;
	import flash.events.SecurityErrorEvent;
	import flash.events.TimerEvent;
	import flash.external.ExternalInterface;
	import flash.media.Sound;
	import flash.media.SoundTransform;
	import flash.net.NetConnection;
	import flash.net.NetStream;
	import flash.net.NetStreamAppendBytesAction;
	import flash.net.URLLoader;
	import flash.net.URLLoaderDataFormat;
	import flash.net.URLRequest;
	import flash.utils.ByteArray;
	import flash.utils.Timer;
	import flash.utils.clearInterval;
	import flash.utils.clearTimeout;
	import flash.utils.setTimeout;

	/**
	 * stream Object to handle http tak streaming.
	 * 
	 * ftfファイルは何度もダウンロードするように変更。
	 * fthファイルのIDが前とかわった場合は、ストリームが変更になっているので、再度アクセスし直す必要がある。
	 * アクセスした場合に、0だった場合はageが進んでいないので、interval分まつ・・・みたいなことにしておく。
	 * なお、読み込んでから余裕がある場合はなるべく遅延するようにした方がいいと思う。
	 * より正確に動作させるために、unixミリ秒をつかった方がよさげ。Date.getTime()で取得できます。
	 */
	public class HtsStream extends FlvStream
	{
		/** logger object */
		private static var logger:Logger = LoggerFactory.getLogger("HtsStream");
		private var fthFile:String;
		private var ftfFile:String;
		private var ftmArray:Array;
		/** length of each packet */
		private var packetInterval:int;
		private var timerId:uint;
		/** fthファイルのID番号、この値が更新された場合は再度fthファイルを読み込む必要あり。 */
		private var fthId:String; // id for fthFile
		private var lastFtmFile:String;
		/**
		 * constructor
		 */
		public function HtsStream()
		{
			// initialize all
			fthFile = null;
			ftfFile = null;
			ftmArray = new Array();
			packetInterval = -1;
			timerId = 0;
			super();
		}
		/**
		 * start to play
		 */
		public function play(htsUrl:String):void
		{
			this.ftfFile = htsUrl;
			// download xml dataa from ftfFile url
			// ftfをダウンロードする。
			downloadXml(ftfFile, onFileLoad);
		}
		/**
		 * close the stream
		 */
		override public function close():void
		{
			super.close();
		}
		private function onFileLoad(data:XML):void {
			var idChangeFlg:Boolean = false;
			// xml tags...
			var base:String = "httpTakStreaming".toLowerCase();
			var interval:String = "packetInterval".toLowerCase();
			var header:String = "flvTakHeader".toLowerCase();
			var media:String = "flvTakMedia".toLowerCase();
			// check the base tag
			if(data.name().localName.toLowerCase() != base) {
				return;
			}
			ftmArray = new Array();
			for each (var element:XML in data.elements()) {
				var name:String = element.name().localName.toLowerCase();
				if(name == interval) {
					try {
						packetInterval = parseInt(element.text());
					}
					catch(e:Error) {
						logger.error(e);
					}
				}
				else if(name == header && fthFile == null) {
					fthFile = element.text();
					if(fthId != element.@id) {
						fthId = element.@id;
						idChangeFlg = true;
					}
				}
				else if(name == media) {
					if(element.text().indexOf("*") != -1) {
						// sequence data
						ftmArray.push({"data": element.text(), "start": element.@start, "age":element.@age});
					}
					else {
						// solid data
						ftmArray.push(element.text());
					}
				}
			}
			// イベントその１ftfファイル取得完了
			dispatchEvent(new HtsEvent(HtsEvent.HTS_EVENT, false, false, {code:"FtfFile.Download"}));
			// 動画データは読み込めるだけ読み込み続ける。
			// starting http tak streaming.
			// download fthFile at the beginning
			if(idChangeFlg) {
				// fthファイルを読み込む
				downloadData(fthFile, onLoadedFthData);
			}
			else {
				// ftmファイルを読み込む (他の処理にCPUをまわすため、0.2秒待たせる。)
				setTimeout(downloadFtmData, 200);
			}
		}
		private function onLoadedFthData(byteArray:ByteArray):void {
			// get fth data before finish flvStream setting up.
			if(!setup()) {
				// must try after flvStream setting up.
				dispatchEvent(new HtsEvent(HtsEvent.HTS_EVENT, false, false, {code:"FthFile.Download.beforeSetup"}));
				return;
			}
			appendHeaderBytes(byteArray);
			// fthファイル取得完了
			dispatchEvent(new HtsEvent(HtsEvent.HTS_EVENT, false, false, {code:"FthFile.Download"}));
			// ftmデータを読み込む(すくなくとも1パケットは定義されているので、それに従う。)
			downloadFtmData();
		}
		private function onLoadedData(byteArray:ByteArray):void {
			// at this point shift up the ftm list
			ftmData(byteArray);
			var data:* = ftmArray.shift();
			// ftmファイル取得完了
			dispatchEvent(new HtsEvent(HtsEvent.HTS_EVENT, false, false, {code:"FtmFile.Download"}));
			if(data is Object && data.start != null && data.data != null) {
				// for sequence data, increment target and put the data bask to ftm list.
				data.start ++;
				ftmArray.unshift(data);
				// ここでは、ageに従ってしばらくまってから、ftfファイルを読み込み直す。
				var timeout:int = packetInterval - parseInt(data.age) * 1000; // 秒で設定されているので、ミリ秒に変更して設定する。
				setTimeout(onTimerEvent, timeout);
			}
			else {
				// VOD用
				setTimeout(downloadFtmData, 200);
			}
		}
		private function downloadFtmData():void {
			// get the targegt ftm file
			var data:* = ftmArray[0];
			if(data is String) {
				if(lastFtmFile == data) {
					setTimeout(onTimerEvent, 500); // 0.5秒後に再度やりなおす。
					return;
				}
				downloadData(data, onLoadedData);
			}
			else if(data is Object && data.start != null && data.data != null) {
				var index:int = data.start;
				var target:String = data.data;
				target = target.replace(/\*/i, index);
				if(lastFtmFile == target) {
					// 現在もっているデータのlivetimeから待つべき時間を計算する。
					var timeout:int = packetInterval - parseInt(data.age) * 1000;
					setTimeout(onTimerEvent, timeout); // 0.5秒後に再度やりなおす。
					return;
				}
				lastFtmFile = target;
				downloadData(target, onLoadedData);
			}
		}
		private function onTimerEvent():void {
			// ftfをダウンロードする。
			downloadXml(ftfFile, onFileLoad);
		}
		private function downloadXml(target:String, task:Function):void {
			var loader:URLLoader = new URLLoader();
			loader.addEventListener(Event.COMPLETE, function(event:Event):void {
				try {
					var data:XML = XML(loader.data);
					task(data);
				}
				catch(e:Error) {
					logger.error(e);
				}
			});
			loader.addEventListener(SecurityErrorEvent.SECURITY_ERROR, function(event:SecurityErrorEvent):void {
				dispatchEvent(new HtsEvent(HtsEvent.HTS_EVENT, false, false, {code:"XML.Download.Error"}));
				logger.error("Xml securityError:" + event);
			});
			loader.addEventListener(IOErrorEvent.IO_ERROR, function(event:IOErrorEvent):void {
				dispatchEvent(new HtsEvent(HtsEvent.HTS_EVENT, false, false, {code:"XML.Download.Error"}));
				logger.error("Xml IOError:" + event);
			});
			var request:URLRequest = new URLRequest(target);
			try {
				loader.load(request);
			}
			catch(e:Error) {
				logger.error(e);
			}
		}
		private function downloadData(target:String, task:Function):void {
			logger.info(target);
			var loader:URLLoader = new URLLoader;
			loader.dataFormat = URLLoaderDataFormat.BINARY;
			loader.addEventListener(Event.COMPLETE, function(event:Event):void {
				task(loader.data as ByteArray);
			});
			loader.addEventListener(SecurityErrorEvent.SECURITY_ERROR, function(event:SecurityErrorEvent):void {
				lastFtmFile = "";
				dispatchEvent(new HtsEvent(HtsEvent.HTS_EVENT, false, false, {code:"Data.Download.Error"}));
				logger.error("Data securityError:" + event);
			});
			loader.addEventListener(IOErrorEvent.IO_ERROR, function(event:IOErrorEvent):void {
				lastFtmFile = "";
				dispatchEvent(new HtsEvent(HtsEvent.HTS_EVENT, false, false, {code:"Data.Download.Error"}));
				logger.error("Data IOError:" + event);
			});
			var request:URLRequest = new URLRequest(target);
			try {
				loader.load(request);
			}
			catch(e:Error) {
				logger.error(e);
			}
		}
		private function ftmData(data:ByteArray):void {
			var length:int = data.length;
			var pos:int = 0;
			try {
				while(true) {
					data.position = 1 + pos;
					var size:uint = ((data.readByte() + 0x0100) & 0xFF) * 0x010000
						+ ((data.readByte() + 0x0100) & 0xFF) * 0x0100
						+ ((data.readByte() + 0x0100) & 0xFF);
					var chunkSize:int = 11 + size + 4;
					var ba:ByteArray = new ByteArray;
					data.position = pos;
					data.readBytes(ba, 0, chunkSize);
					// ba is the target packet data.
					appendBytes(ba);
					pos += chunkSize;
					if(pos == length) {
						break;
					}
				}
			}
			catch(e:Error) {
				logger.error(e);
			}
		}
	}
}