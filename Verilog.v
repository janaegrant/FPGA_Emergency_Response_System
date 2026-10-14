module Verilog(
/*------------------------INPUTS--------------------------------------------------

switch to simulate distaer {01=disater, 00=no disater}

accelerometer for mobility {01=active, 00=inactive}

switch for pulse simulation {SW1= Normal, SW2= Emergent, SW3= no pulse}

button for distres signal {00= not pressed, 01= distress signal, 10= recall signal}

clock1- How long has button been pressed (Distress timer) and how long was the last movement 

Light sensor from Arduino- triggers LED on FPGA also triggers Ardunio Buzzer 

---------------------------INPUTS---------------------------------------------------*/
input wire MAX10_CLK1_50,         // 50MHz system clock
input wire [9:0] SW,             // SW[0]=disaster, SW[2:1]=pulse, SW[3]=found
input wire [1:0] KEY,            // KEY[0]=distress button, KEY[1]=cancel
input wire moving,         // 1 = movement detected
input wire [1:0] light_level,    // from Arduino
/*------------------------OUTPUTS-----------------------------------------------------	

signal to Arduino- Trigger by the disater switch 
->Triggers the Light sensor - Did not have resistore to operate Light sensor
->Sends out SOS signal via buzzer based on pulse sensor 

HEX display Distress timer

LED	-System has started
-Light sensor triggered
-Level of emergency based on pulse (flashes)

---------------------------OUTPUTS---------------------------------------------------*/
output wire [9:0] LEDR,           // physical LEDs on board
output reg [1:0] alert_level,    // 00=normal, 01=warning, 10=SOS
output reg [6:0] HEX0,           // seconds (ones)
output reg [6:0] HEX1,           // seconds (tens)
output reg [6:0] HEX2,           // minutes (ones)
output reg [6:0] HEX3,           // minutes (tens)
output reg [6:0] HEX4,           // hours (ones)
output reg [6:0] HEX5,            // hours (tens)
output reg ARDUINO_LED,    // signal to Arduino (simple test)
output reg ARDUINO_SOS     // SOS pulse output to Arduin
);

/*---------------------------------Finate State Machine-----------------------------
States (3 bits, for example):
S0_IDLE: System waiting, no disaster active
S1_START: Disaster detected, system initializing
S2_BUTTONPRESS: User has pressed distress button (distress_active = 1)
S3_AUTO_MON: System automatically monitoring (no user distress)
S4_SOS: Emergency state (SOS alert)
S5_RESET: Clear alerts and return to idle/monitor

Button behaviour (toggle):
- On a button press event:
if distress_active == 0 -> set distress_active = 1, go to S2_BUTTONPRESS
if distress_active == 1 -> set distress_active = 0, go to S5_RESET

'found' behaviour (auto stop):
- If found == 1 in ANY active state (S1, S2, S3, or S4):-> go directly to S5_RESET (stop alerts, clear timers).

S0_IDLE:
- if quake == 1          -> S1_START
- else                   -> stay in S0_IDLE

S1_START:
- reset all timers and counters
- if button pressed      -> S2_BUTTONPRESS   (distress_active = 1)
- else                   -> S3_AUTO_MON

S2_BUTTONPRESS (user distress mode):
- start/continue distress timer (how long in distress)
- monitor pulse, mobility, light
- if button pressed again (distress_active was 1) -> S5_RESET
- else if (pulse == NO_PULSE)
 or (faint_pulse for > T_FAINT_ESC)
 or (no_movement for > T_NOMOVE_ESC)
-> S4_SOS
- else -> stay in S2_BUTTONPRESS

S3_AUTO_MON (automatic monitoring):
- monitor pulse, mobility
- if button pressed (first time) -> S2_BUTTONPRESS (distress_active = 1)
- else if (pulse == NO_PULSE)
 or (faint_pulse for > T_FAINT_ESC)
 or (no_movement for > T_NOMOVE_ESC)
-> S4_SOS
- else -> stay in S3_AUTO_MON

S4_SOS (emergency):
- assert SOS alert (LED, BUZZER & alert_level = SOS)
- if button pressed (Distress cancels) -> S5_RESET
- else -> stay in S4_SOS

S5_RESET:
- clear timers, alerts, distress_active flag

Extra timing rule (optional):
- If distress timer > 24h in S2 or S3, enable special long beep
or special display pattern on HEX (but state can remain S2/S3).
---------------------------------Finate State Machine-----------------------------*/
//----------------- INTERNAL SIGNALS -----------------
reg distress_active;// 1 = user in distress mode
reg prev_distress; // for edge detect
reg [4:0] current_state;

// Timers
reg [31:0] distress_timer;
reg [31:0] no_movement_timer;
reg [31:0] faint_timer;

reg [3:0] sec_ones, sec_tens;
reg [3:0] min_ones, min_tens;
reg [3:0] hr_ones, hr_tens;
// From switches
wire [1:0] pulse = SW[2:1]; // 00=normal, 01=emergent, 10=no pulse
wire disaster = SW[0];//disater has happened yes or no
wire found = SW[3];//has user been found
// Latch "found" event (one-way)
reg found_latched;
// Active-low push button
wire distress = ~KEY[0];
			
//------------------------ OUTPUT REGISTERS ------------------------
reg system_on;//Start state
reg alert_green;//Start state 
reg alert_yellow;//distress state 
reg alert_red;//SOS state 
reg [3:0] sos_step;
reg [3:0] sos_count;
reg sos_led;
// LEDR for debugging
assign LEDR[9] = system_on;
assign LEDR[0] = alert_green;
assign LEDR[8] = alert_yellow;
assign LEDR[7] = alert_red;
// Show pulse bits on LEDs
assign LEDR[1] = (current_state == S4_SOS) ? sos_led : SW[1];
assign LEDR[2] = (current_state == S4_SOS) ? sos_led : SW[2];

//------------------ TIMING REGISTERS (hh:mm:ss) -------------------
//Duration trackers 
reg [5:0] seconds;// 0–59
reg [5:0] minutes;// 0–59
reg [6:0] hours;// 0–99
reg time_en;// 1 = timer running

// thresholds
localparam integer T_emergent_SOS = 10;  // seconds
localparam integer T_NOMOVE_SOS = 60;  // seconds not being used as i can use teh accelerator 

wire SOS = (pulse == 2'b10)||(pulse == 2'b01 && faint_timer >= T_emergent_SOS)
				||(moving == 1'b0 && no_movement_timer >= T_NOMOVE_SOS);//used in S2 and S3 

//------------------------ FSM STATE DEFINITIONS --------------------
localparam S0_IDLE = 5'd0;
localparam S1_START = 5'd1;
localparam S2_BUTTONPRESS = 5'd2;
localparam S3_AUTO_MON = 5'd3;
localparam S4_SOS = 5'd4;
localparam S5_RESET = 5'd5;

//----------------------------- INITIAL VALUES ----------------------
initial begin
	current_state = S0_IDLE;
	distress_active = 1'b0;
	prev_distress = 1'b0;
	found_latched = 1'b0;

	distress_timer = 32'd0;
	no_movement_timer = 32'd0;
	faint_timer = 32'd0;

	system_on = 1'b0;
	alert_green = 1'b0;
	alert_yellow = 1'b0;
	alert_red = 1'b0;
	alert_level = 2'b00;

	seconds = 6'd0;
	minutes = 6'd0;
	hours = 7'd0;
	time_en = 1'b0;

	HEX0 = 7'b1111111;
	HEX1 = 7'b1111111;
	HEX2 = 7'b1111111;
	HEX3 = 7'b1111111;
	HEX4 = 7'b1111111;
	HEX5 = 7'b1111111;
end

//------------------System reset-------------------
/*Once SW3 is flipped system end, can't be on done (on-way)
		logical lacth implementation*/
always @(posedge MAX10_CLK1_50) begin
// If no disaster, clear the found flag
	if (!disaster) begin
		found_latched <= 1'b0;
	end
// once found end system
	else if (found) begin
	found_latched <= 1'b1;
	end
// else keep previous value
end

/*-------------------FSM (states and outputs)--------------*/
always @(posedge MAX10_CLK1_50) begin
	case (current_state)

//--------------------- S0_IDLE -----------------------
		S0_IDLE: begin
			system_on <= 0;
			alert_green <= 0;
			alert_yellow <= 0;
			alert_red <= 0;
			alert_level <= 2'b00;
			time_en <= 0;

			if (disaster)
				current_state <= S1_START;
			else
				current_state <= S0_IDLE;
		end

//--------------------- S1_START ----------------------
		S1_START: begin
			system_on <= 1;
			alert_green <= 1;
			alert_yellow <= 0;
			alert_red <= 0;
			alert_level <= 2'b00;
			time_en <= 1;  // enable timer

			if (found_latched)
				current_state <= S5_RESET;
			else if (distress_active)
				current_state <= S2_BUTTONPRESS;
			else
				current_state <= S3_AUTO_MON;
		end

//------------------- S2_BUTTONPRESS ------------------
		S2_BUTTONPRESS: begin
			system_on <= 1;
			alert_green <= 0;
			alert_yellow <= 1;
			alert_red <= 0;
			alert_level <= 2'b01; // warning
			time_en <= 1;

			// found or user cancels distress (2nd press)
			if (found_latched || (distress_active == 1'b0))
				current_state <= S5_RESET;
			else if (SOS)
				current_state <= S4_SOS;
			else
				current_state <= S2_BUTTONPRESS;
		end

//------------------- S3_AUTO_MON ---------------------
		S3_AUTO_MON: begin
			system_on <= 1;
			alert_green <= 1;
			alert_yellow <= 0;
			alert_red <= 0;
			alert_level <= 2'b00;
			time_en <= 1;

			if (found_latched)
				current_state <= S5_RESET;
			else if (distress_active)
				current_state <= S2_BUTTONPRESS;
			else if (SOS)
				current_state <= S4_SOS;
			else
				current_state <= S3_AUTO_MON;
		end

//--------------------- S4_SOS ------------------------
		S4_SOS: begin
			system_on <= 1;
			alert_green <= 0;
			alert_yellow <= 0;
			alert_red <= 1;
			alert_level <= 2'b10;// SOS
			time_en <= 1;

			if (!distress_active || found_latched)
				current_state <= S5_RESET;
			else if(!SOS) 
				if (distress_active)
					current_state <= S2_BUTTONPRESS;
				else 
					current_state <= S3_AUTO_MON; 
			else 
				current_state <= S4_SOS;
		
	end
//--------------------- S5_RESET ----------------------
		S5_RESET: begin
			system_on <= 0;
			alert_green <= 0;
			alert_yellow <= 0;
			alert_red <= 0;
			alert_level <= 2'b00;
			time_en <= 0;
			current_state <= S5_RESET;// Stay in FOUND mode forever (until board reset)
		end

//--------------------- DEFAULT -----------------------
		default: begin
			system_on <= 0;
			alert_green <= 0;
			alert_yellow <= 0;
			alert_red <= 0;
			alert_level <= 2'b00;
			time_en <= 0;
			current_state <= S0_IDLE;
		end
	endcase
end
//----------------------------END OF FSM---------------------------
/*--------------------- 1 Hz TICK GENERATOR -----------------------*/
reg [25:0] tick_count;
reg tick_1hz;

always @(posedge MAX10_CLK1_50) begin
	if (!time_en) begin
		tick_count <= 26'd0;
		tick_1hz <= 1'b0;
	end 
	else begin
		if (tick_count == 26'd49_999_999) begin
			 tick_count <= 26'd0;
			 tick_1hz <= 1'b1;
		end 
		else begin
		 tick_count <= tick_count + 1'b1;
		 tick_1hz <= 1'b0;
		end
	end
end

/*------------------- 4 Hz Tick (every 0.25s) -------------------*/
reg [23:0] tick4_cnt;
reg tick_4hz;

always @(posedge MAX10_CLK1_50) begin
	if (tick4_cnt >= 24'd12_499_999) begin
		tick4_cnt <= 0;
		tick_4hz <= 1;
	end 
	else begin
		tick4_cnt <= tick4_cnt + 1;
		tick_4hz <= 0;
	end
end

wire distress_rise = distress && !prev_distress;//uses rising edge detction

always @(posedge MAX10_CLK1_50) begin
	prev_distress <= distress;

	if (!time_en) begin
		distress_active <= 1'b0;
	end 
	else if (distress_rise) begin
		distress_active <= ~distress_active;// toggle each press
	end
end

/*------------------ Main time counter (hh:mm:ss) -----------------*/
always @(posedge MAX10_CLK1_50) begin
// Clear the time on ANY distress press or when found_latched
	if (distress_rise || found_latched) begin
		seconds <= 0;
		minutes <= 0;
		hours <= 0;
	end 
	else if (tick_1hz && time_en) begin
		if (seconds == 6'd59) begin
			seconds <= 0;
				if (minutes == 6'd59) begin
					minutes <= 0;
						if (hours == 7'd99)
							hours <= 0;
							else
								hours <= hours + 1;
							end 
							else begin
							minutes <= minutes + 1;
						end
				end 
		else begin
			seconds <= seconds + 1;
		end
	end
	// if !time_en and no clear → freeze hh:mm:ss
end

/*------------------- FAINT PULSE TIMER ---------------------------*/
always @(posedge MAX10_CLK1_50) begin
	if (!time_en) begin
		faint_timer <= 0;
	end else if (tick_1hz) begin
		if (pulse == 2'b01)
		faint_timer <= faint_timer + 1;
	else
		faint_timer <= 0;
	end
end

//------------------- NO MOVEMENT TIMER ---------------------------
always @(posedge MAX10_CLK1_50) begin
	if (!time_en) begin
		no_movement_timer <= 0;
	end else if (tick_1hz) begin
		if (moving == 1'b0)
			no_movement_timer <= no_movement_timer + 1;
		else
			no_movement_timer <= 0;
	end
end

//------------------- DISTRESS TIMER -------------------------
always @(posedge MAX10_CLK1_50) begin
	if (!time_en) begin
		distress_timer <= 0;
	end else if (tick_1hz) begin
		if (distress)
			distress_timer <= distress_timer + 1;
		else
			distress_timer <= 0;
	end
end

//---------------------hh:mm:ss INTO DIGITS ------------------
always @(*) begin
sec_tens = seconds / 10;//xx xx x0
sec_ones = seconds % 10;//xx xx 0x
min_tens = minutes / 10;//xx x0 xx
min_ones = minutes % 10;//xx 0x xx
hr_tens = hours / 10;//x0 xx xx
hr_ones = hours % 10;//0x xx xx
end

//------------------- Time Display 0-1 -------------------------
function [6:0] num_hex;
input [3:0] digit;
begin
case (digit)
	 4'd0: num_hex = 7'b1000000;//0
	 4'd1: num_hex = 7'b1111001;//1
	 4'd2: num_hex = 7'b0100100;//2
	 4'd3: num_hex = 7'b0110000;//3
	 4'd4: num_hex = 7'b0011001;//4
	 4'd5: num_hex = 7'b0010010;//5
	 4'd6: num_hex = 7'b0000010;//6
	 4'd7: num_hex = 7'b1111000;//7
	 4'd8: num_hex = 7'b0000000;//8
	 4'd9: num_hex = 7'b0010000;//9
	 default: num_hex = 7'b1111111; // blank
endcase
end
endfunction

//------------------- SOS COUNTER (5s) --------------------
reg [3:0] sos_counter;
wire show_sos = (current_state == S2_BUTTONPRESS) && (sos_counter < 4'd5);
//display SOS for 5secs 
always @(posedge MAX10_CLK1_50) begin
if (!time_en || current_state != S2_BUTTONPRESS) begin
sos_counter <= 4'd0;
end else if (tick_1hz && sos_counter < 4'd5) begin
sos_counter <= sos_counter + 1'b1;
end
end

/*------------------- SOS LED FLASHER -------------------
Pattern for SOS:
S = * * *   → (1,1,1)
O = -- -- -- → (3,3,3)
Each ON section followed by 1 tick OFF
*/
always @(posedge MAX10_CLK1_50) begin
	if (current_state != S4_SOS) begin
	  sos_step <= 0;
	  sos_count <= 0;
	  sos_led <= 0;
	end 
	else if (tick_4hz) begin// changes once per 0.25 sec 
		case (sos_step)
//number 0-12 are the stages of the SOS 
// S: --
			0, 2, 4: begin  //* on 
			sos_led <= 1;
			if (sos_count == 1) begin
				sos_count <= 0;
				sos_step  <= sos_step + 1;
			end 
			else begin
				sos_count <= sos_count + 1;
			end
			end

			1, 3, 5: begin //* off
			sos_led <= 0;
			if (sos_count == 1) begin
				sos_count <= 0;
				sos_step <= sos_step + 1;
			end 
			else begin
				sos_count <= sos_count + 1;
			end
		end

// O: --
		6, 8, 10: begin //-- on
			sos_led <= 1;
			if (sos_count == 3) begin
				sos_count <= 0;
				sos_step <= sos_step + 1;
			end else begin
				sos_count <= sos_count + 1;
			end
		end

		7, 9, 11: begin// --off
			sos_led <= 0;
			if (sos_count == 1) begin
			  sos_count <= 0;
			  sos_step  <= sos_step + 1;
			end else begin
			  sos_count <= sos_count + 1;
			end
		end

// Restart SOS
			12: begin
				 sos_step <= 0;
				 sos_count <= 0;
			end

			default: sos_step <= 0;
		endcase
	end
end

//------------------- Letters display for "SOS" & "FOUND" ---------
localparam [6:0] SEG_BLANK = 7'b1111111;
localparam [6:0] SEG_O = 7'b1000000; //looks like "O"
localparam [6:0] SEG_0 = 7'b0100011; // looks like "o"
localparam [6:0] SEG_S = 7'b0010010; // like "5"
localparam [6:0] SEG_F = 7'b0001110; // F
localparam [6:0] SEG_U = 7'b1100011; // u 
localparam [6:0] SEG_N = 7'b0101011; // n 
localparam [6:0] SEG_D = 7'b0100001; // d

//------------------- HEX DISPLAY MUX -----------------------------
always @(*) begin
// show found
if (current_state == S5_RESET) begin
	HEX5 = SEG_F;
	HEX4 = SEG_0;
	HEX3 = SEG_U;
	HEX2 = SEG_N;
	HEX1 = SEG_D;
	HEX0 = SEG_BLANK;
end 
// show SOS for first 5s 
else if (show_sos) begin
	HEX5 = SEG_S;
	HEX4 = SEG_O;
	HEX3 = SEG_S;
	HEX2 = SEG_BLANK;
	HEX1 = num_hex(sec_tens);
	HEX0 = num_hex(sec_ones);
end 
// Normal clock display
else begin
	HEX0 = num_hex(sec_ones);
	HEX1 = num_hex(sec_tens);
	HEX2 = num_hex(min_ones);
	HEX3 = num_hex(min_tens);
	HEX4 = num_hex(hr_ones);
	HEX5 = num_hex(hr_tens);
end
end

//----------------Arduino----------------------

always @(*) begin
   ARDUINO_LED = (current_state == S4_SOS) ? sos_led : SW[1];
	//my buzzer isnt coressponding
	//needed additional hardware (which i couldn't get for sensor), as they are analog so decided agaisnt it 
end
endmodule
